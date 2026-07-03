> Провенанс: собрано отдельной сессией 2026-07-03 (~05:40Z, ДО полного деплоя того же дня); спасено из эфемерного scratchpad в канон 2026-07-03. Деплой-правила Корзины C частично устарели — актуальная сверка в 2026-07-03-remediation-strategy.md.

# crewboss — фактура инцидента 2026-07-02/03 (RL-strangle + клинч-класс)

> Собрано read-only с живого бокса (ssh ec2-user@3.217.199.168) и локального клона `~/Projects/crewboss`.
> Цель документа: починить процесс так, чтобы **после деплоя #1274/#1290 не сломалось снова**.
> Часть I (ниже) — операционная фактура с бокса. Часть II (код-аудит main + deploy-safety) — из фонового workflow-аудита, дописывается по завершении.

## Состояние репозитория (ground truth, `git fetch` 2026-07-03 ~05:40Z)

- **main СОДЕРЖИТ:** #1274 (RL v2, finale PR #1312, merge 20:47Z) + #1290 (infra-red≠code-red, finale PR #1318). Ключевые коммиты #1290: `fix(#1303) classify env-fail as retryable infra red, never confirmed code red`, `fix(#1304) triage crash-death survives RL-storm, retries instead of terminal park`, `fix(#1305) rework-PR hygiene`, `infra(#1306) safe between-ticks deploy`. #1274: `feat(#1298) RL guard v2 dual-source cross-identity + GraphQL diet`, `infra(#1301) wire gh-shim into deploy+spawn`, `security(#1300) token-handling review`.
- **main НЕ содержит #1291** — WIP на `origin/charter/1291` (заблокирован, см. D8/D9). Double-zero баг живёт на этой ветке, не в main.
- **Бокс деплойнут СТАРЫМ лаунчером** (`~/cbnet/crewboss-launcher-gh.sh`, 30 июня + ручные патчи). merge≠deploy: фиксы в main НЕ активны на боксе. Деплой-набор в репо: `reference/runtime/{crewboss-launcher-gh.sh,gh-shim.sh,crewboss-spawn.sh,crewboss-prep-spawn-gh.sh,crewboss-loop-keepalive.sh,run-env.sh}` + снимок `_box-snapshot/cbnet/*`.

## Таймлайн (UTC)

| Время | Событие |
|---|---|
| 2026-07-02 ~10:56 | Реап plan-review #1274 ловит дохлое GraphQL-окно → ложный «ревью провалено» → tries=2=cap → route blocked, но label-write умер, `sset term 1` записался. **Начало клинча #1274** (D3→D4). |
| ~10:56–18:43 | #1274 висит `status:plan-review`+`plan:agreed`, но `term=1` → gate и limbo-reconciler скипают. 8ч застоя, борд тихий → лаунчер жив (дешёвые тики). |
| 18:43:45 | **Оператор (с согласия): `rm state/1274/{term,tries}`** → следующий тик gate сам: `#1274 plan:agreed → status:approved (leaves released)`. Клинч снят. |
| 18:44 | Спавн: `#1290 solution-analyst --model claude-fable-5` (модельная политика live!) + `#1297 executor` (лист #1274). Борд зачурнился. |
| 18:58 / 19:01 / 19:06 | `idle — run complete` ×3 — **D5 false-idle-exit**: GraphQL выжжен (D1), лаунчер принял «не читаю борд» за idle и вышел. |
| 19:00 / 19:05 / 19:10 | keepalive.out: `loop DOWN -> direct launch` ×3 — **D6 respawn-strangle** (каждые 5 мин). GraphQL: remaining=0/5000, user ID 35860020 (owner). |
| 19:16:50 | **Оператор (с согласия): `CB_POLL 20→120` + чистый рестарт** (`kill -TERM -<pgid>`; `keepalive --once`). Бёрн упал 7200→~600-860/час. Респавн-strangle прекратился. |
| 19:17–20:15 | Петля жива на CB_POLL=120. Но приёмка #1274 стоит: PR #1307 (лист #1297) `OPEN/MERGEABLE`, но **лист застрял `status:in-progress`** (флип→review умер в шторме) — **D7**. |
| 20:15:05 | **Оператор (с согласия): флип #1297 `status:in-progress→status:review`** → integrator сам `verify-merged=pass → merged` PR #1307, закрыл #1297, релизнул #1298/#1299. |
| 20:15–20:47 | Листья #1308–#1311 смёржены; **finale #1312 (#1274)→main merge 20:47**. #1290 тоже добит (finale #1318). |
| 23:16–00:37 | #1291 листья #1334–#1337 смёржены в charter/1291. |
| 00:37–01:11 | Финальный ревью #1333 (`role:reviewer`) отработал (exit 0, вердикт `❌ BLOCKED — test-suite RED`, нашёл D9), но PR не открыл (ревьюер и не должен). Интегратор: `in review but no open PR — skip (stale 1/10 … 10/10)` → `review-stale — blocking`. **D8**. |
| 01:11 → 05:34+ | Очередь `order=[1291] head=#1291` стоит ~4.5ч. Лаунчер жив (тот же pid 325828 с 19:16 — **CB_POLL=120 выстоял 10ч без strangle**), GraphQL здоров. |

## Наблюдавшиеся дефекты (операционная фактура)

- **D1 self-strangulation** — ~20 репагинаций/тик (>600 issues) через GraphQL без кэша; замер 7200/час > ведро 5000 при активном борде. Тихий борд дёшев (ETag). Комментарий в шапке деплойнутого скрипта :76 «~20× repaginations/tick, CB_POLL→~180 ticks/h».
- **D2 guard blind to GraphQL** — `_cb_rl_remaining` читал только `.resources.core.remaining`. `gh api /rate_limit` врёт про repo-ведро (live: rem=4972, а реальный GET → 403 Used:5000). Правда только в X-Ratelimit заголовках реальных вызовов.
- **D3 infra≠business (корень)** — деплой ~:1302 `_plok=$(gh issue view ... plan:agreed ... || echo "false")`: RL-фейл = «нет agreement». Тот же класс: смоук `board-empty`→RED, триаж «no verdict».
- **D4 term-guard clinch** — `term=1` (файл) записался, `route blocked` (label) умер → рассинхрон навсегда; term-гард в gate (~:1933) и limbo-reconciler #957 (~:1995) скипают по флагу сбоя; queue морозит очередь за plan-head.
- **D5 false-idle-exit** — 19:06 `idle — run complete` при выжженном GraphQL (не мог прочитать борд).
- **D6 respawn-strangle** — keepalive 5-мин респавн × стартовая репагинация = самоподдерживающийся цикл. keepalive.out 19:00/19:05/19:10.
- **D7 leaf status:review divergence** — #1297: `term=1`+PR#1307 open, но лейбл застрял `status:in-progress`; приёмка смотрит только на `status:review`.
- **D8 reviewer-leaf misclassification** — #1333 `role:reviewer`, продукт=коммент-вердикт, интегратор ждал PR → 10 stale → blocked, вердикт не обработан. review-stale path ~:463-468.
- **D9 double-zero bomb** — `finale-hygiene.test.sh:349` (charter/1291) `_nbare=$(grep -c bare-clone ... || echo 0)` → `0\n0` → крэш integer-теста. Тот же `|| echo` класс.
- **D10 deploy gap** — ручные боксовые патчи под угрозой перезатирания: token-split (spawn.sh), CB_POLL=120 (~/.crewboss.env), per-role models (team-selfbuild + .claude/agents), роли triage/reviewer/recovery-lead, keepalive kill-mode.

## Операторские вмешательства (все с явного согласия, все read/минимально-мутирующие)

1. `rm state/1274/{term,tries}` → расклин #1274 (D4). Петля сама флипнула в approved.
2. `CB_POLL 20→120` + рестарт → стоп strangle (D1/D5/D6). Выстоял 10ч.
3. флип #1297 `status:in-progress→status:review` (лейбл-only) → приёмка поехала (D7). Мержить руками в обход ревью НЕ стал.

Все три — реконсиляция расхождений, вызванных RL, а не обход гейтов. Настоящее лечение — деплой #1274/#1290 (класс D3/D4) + чартеры на непокрытое.

---
## Часть II — код-аудит main + deploy-safety

> Источник: read-only workflow-аудит (4 агента Explore + синтез) против `origin/main`, **несущие claim'ы верифицированы прямым грепом оператора** (main launcher = 2818 строк). CONFIRMED = подтверждено грепом; иное = находка агента (haiku), доверять с проверкой.

### ГЛАВНЫЙ ВЫВОД
**Деплой #1274/#1290 НЕОБХОДИМ, но НЕДОСТАТОЧЕН — корневой класс останется латентным и рванёт снова под RL-давлением.** main чинит guard (D2) и triage crash-death (D4a), но НЕ чинит: infra≠business маскирование (D3), term-клинч (D4b), false-idle-exit (D5), leaf-divergence (D7), reviewer-misclassification (D8). Плюс GraphQL-диета (D1) — **мёртвый код (0 вызовов)** → бёрн не снижен → **CB_POLL=120 откатывать НЕЛЬЗЯ**.

> ⚠️ Коррекция моего раннего заявления в этой сессии: я говорил «лечение корневого класса D3/D4 уже в main» — **это неверно**. В main только D2 (guard) и D4a (crash-death). Первазивный `|| echo false` + безусловный `sset term 1` остались.

### Корзина A — УЖЕ пофикшено в main (с доказательством)
| ID | Что | Доказательство |
|---|---|---|
| **D2** | guard видит оба ведра | launcher `_cb_rl_backoff` триггерит при core<1000 ИЛИ graphql<800; dual-source через CB_RL_STATE_FILE. **Работает — но только если shim реально пишет state-file (проверить на боксе).** |
| **D4a** | triage crash-death не паркуется с первой смерти | `CB_TRIAGE_MIN_LIFETIME=60`; lifetime<MIN → retry до `CB_TRIAGE_RETRY_CAP=3`, term=1 только после cap |
| **D10b** | per-role models канон в репо | `.claude/agents/*.md` frontmatter model: (fable-5 лиды / opus-4-8 исполнители). Деплой-безопасно |

### Корзина B — ЛАТЕНТНО, рванёт после деплоя → нужен чартер
| ID | Что | Доказательство (main) | Sev |
|---|---|---|---|
| **D3-read** | инфра-фейл gh-read = ложный бизнес-негатив | **CONFIRMED: 15× `\|\| echo "false"` + 14× `\|\| echo "[]"`.** Ключ: `:1796 _plok=$(gh issue view … plan:agreed … \|\| echo "false")` = реап-чек, заклинивший #1274; `:1775 review:agreed`; `:1640 plan:agreed`; `:543` (см. D5) | **blocker** |
| **D3-write** | инфра-фейл gh-edit = тихая потеря лейбла | **CONFIRMED: 34× `gh issue edit`, 127× `\|\| true`** (лейбл-эдиты маскируют RL-фейл записи) | **blocker** |
| **D4b** | term=1 безусловно после падающего label-edit → клинч | **CONFIRMED: `:2600` edit approved `\|\| true` → `:2601 sset term 1`; `:2682/:2683` тот же баг в limbo-reconciler**; gate скипает по `[ -n term ]` | **blocker** |
| **D5** | false-idle-exit при RL | **CONFIRMED: `:543 _all_issues=$(_cb_issue_list all 2>/dev/null \|\| echo "[]")` в `_loop_is_alive` (:523)** → пустой борд = idle → exit (2 тика CB_IDLE_CONFIRM) | **blocker** |
| **D6** | respawn-strangle | keepalive атомарность пофикшена, но root D5 жив → exit→restart→RL→exit цикл 5 мин | high |
| **D7** | leaf status:review divergence | `:2157 board route review` может упасть (RL), term=1 всё равно; нет реконсиляции; после 10 тиков review-stale→blocked ложно | high |
| **D8** | reviewer-leaf misclassification | **CONFIRMED: `:2157 done) board route "$id" review` — БЕЗ проверки role.** role:reviewer (продукт=коммент) ждёт PR → 10 тиков → blocked (случай #1333) | high |
| **D1** | GraphQL-диета = мёртвый scaffold | **CONFIRMED: `_cb_issue_labels_cached` 0 вызовов (только def :267); батчер не подключён.** Бёрн ~20-32×/тик не снижен | high |
| **D9** | double-zero bomb | `finale-hygiene.test.sh:349` (только charter/1291) `grep -c … \|\| echo 0` → `0\n0` крэш. НЕ в main | high |
| **D11** | `grep -c … \|\| echo 0` в 100+ тестах main | EXCLUDED из per-leaf verify-merged → не блокирует, но рванёт в полном GHA | medium |
| **D12** | runtime не линтуется | `run-test-quality-gate.sh` сканит только `reference/tests/*`, лаунчер (30+ D3-паттернов) — вне линта | high |

### Корзина C — DEPLOY-SAFETY (сохранить/переприменить руками, иначе слетит)
1. **Инструмент деплоя — ТОЛЬКО `deploy-live-swap.sh`** (5 файлов: launcher, integrator, smoke-runner, cb-pr-create, rework-prep). **НИКОГДА `deploy-runtime.sh`** во время живой петли — он перезатирает spawn-скрипты, роли, shim, рестартит API. Риск: потеря token-split, CB_POLL, ролей triage/reviewer.
2. **Token-split**: если инъекция `CB_SESSION_GH_TOKEN` живёт в боксовом `crewboss-spawn.sh` — deploy-live-swap её НЕ трогает (safe); при deploy-runtime — бэкап + переприменить.
3. **Роли triage/reviewer НЕ в манифесте** (боксовые-only) — full-deploy их осиротит. Занести в `team-example/roles/` + манифест ДО любого full-deploy.
4. **CB_RL_STATE_FILE**: проверить post-deploy что shim в джейле реально пишет файл (иначе D2-guard видит только своё ведро → инцидент повторится).
5. **CB_POLL=120 НЕ откатывать** пока не подтверждено, что диета (D1) реально снижает бёрн — а она мёртвый код, так что **держать 120** до чартера D1. Откат — только через `~/.crewboss.env`, не в коде.

### DEPLOY-SAFETY CHECKLIST
**BEFORE:** бэкап launcher+spawn+`.claude/agents`; проверить writable CB_RL_STATE_FILE dir; записать baseline (tick.count, graphql-spend, CB_POLL).
**DURING:** `deploy-live-swap.sh` (не runtime); если всё же runtime — сперва kill-switch, чистый выход, потом swap, потом восстановить роли/токен/CB_POLL.
**AFTER:** 1 здоровый тик (tick.count растёт, нет idle-exit); grep `rate-limit pressure` — должны быть ОБА пула (core+graphql), иначе shim не пишет; следующие 10 тиков — нет false-idle (D5), нет term-клинчей (D4b), нет ложных review-stale (D7/D8); **НЕ откатывать CB_POLL** пока graphql-spend не подтверждён низким.

### ПРЕДЛАГАЕМЫЕ ЧАРТЕРЫ (формулировки для доски — НЕ создано)
1. **infra≠business (D3+D5 root)** — заменить все `gh … \|\| echo false/[]` на явную обработку: read-fail → log+backoff (не бизнес-негатив); write-fail → requeue+backoff (не безусловный term=1); `_loop_is_alive` → отличать RL-blocked от genuine-empty. Тест: симуляция 403 → петля НЕ роутит/не выходит ложно. Покрывает D3-read/D3-write/D5.
2. **term-atomicity (D4b+D7)** — перед `sset term 1` проверять код возврата label-edit; при фейле — retry, не term. Затрагивает :2600 (gate), :2157 (leaf review), :2682 (limbo). Тест: RL-фейл записи → чартер остаётся recoverable.
3. **reviewer-leaf role-aware routing (D8)** — в :2157 ветка: role==reviewer → terminal-done (без PR); интегратор пропускает reviewer-листья. Тест: reviewer-лист → done, не отслеживается merge-гейтом.
4. **GraphQL-диета: подключить мёртвый scaffold (D1)** — вписать `_cb_issue_labels_cached` во все label-read пути, батчер в label-write. Замер до/после (<5 read/тик, 1-2 edit/тик). Разблокирует откат CB_POLL.
5. **shell anti-pattern линт (D9+D11+D12)** — расширить `run-test-quality-gate.sh` на `reference/runtime/*` + детект `grep -c … \|\| echo` и double-zero; вынести в pre-commit gate.
6. **RL-state-file деплой+верификация (D2 completion/D10a)** — post-deploy проверка, что shim пишет CB_RL_STATE_FILE, guard читает оба пула.

### COMPLETENESS / оговорки
- Агенты шли на haiku; несущие claim'ы (D1 мёртвый scaffold, D3 счётчики, D4b/D5/D8 строки) — **верифицированы грепом оператора, CONFIRMED**. Остальные (deploy-скрипты deploy-live-swap.sh/deploy-runtime.sh поведение, CB_RL_STATE_FILE запись shim'ом) — **на боксе не проверялись read-only**, проверить перед деплоем.
- Не проверено вживую: реально ли `deploy-live-swap.sh` существует на боксе и что в его FILES=(); пишет ли задеплоенный gh-shim state-file; актуальный `CB_IDLE_CONFIRM`/`CB_REVIEW_STALE_TICKS` на боксе.
- Пороговая правда RL — только X-Ratelimit заголовки реальных вызовов (`/rate_limit` врёт про repo-ведро).
