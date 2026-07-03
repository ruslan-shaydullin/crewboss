# Стратегия лечения после ночи 2026-07-02/03 — объединение двух фактур

Единый план поверх двух независимых разборов:

- **Фактура A** — `2026-07-03-night-run-error-factology.md` (78 агентов, инцидент/процесс-уровень: борд, чартеры, бокс-логи, деплой; каждая находка адверсариально верифицирована; темы A–J, ~70 находок).
- **Фактура B** — `2026-07-03-rl-strangle-dossier.md` (код-аудит main 2818-строчного лаунчера, греп-верифицированные счётчики и строки; дефекты D1–D12; собрана ДО деплоя 07-03).

Обе сходятся в одном тезисе: **merged ≠ deployed ≠ validated-live**, и петля системно врёт себе под RL-давлением.

## 1. Сверка фактур (маппинг и коррекции)

| B (код) | A (процесс) | Статус после сверки |
|---|---|---|
| D1 диета = мёртвый код (0 вызовов) | E3 p2-gql-diet-shipped-as-dead-code | Совпало дословно. **CB_POLL=120 не откатывать** до подключения + замера |
| D2 dual-pool guard (нужен живой shim) | E8 rl-v2-core-diagnosis | Задеплоено 07-03; вайринг проверен: shim пишет `/cbnet/run/rl_state` (явный `--env` в spawn:109), лаунчер читает `$CB_HOME/run/rl_state` — тот же файл. Live-проверка = первая jail-сессия (чекпойнт §4) |
| D3-read (15× `\|\| echo "false"`, 14× `\|\| echo "[]"`, ключ :1796) + D3-write (127× `\|\| true`) | D5 (цепочка клинча #1274), E5, E6 | Взаимно подтверждено: B даёт полный кодовый ценз, A — инцидентные цепочки. **Blocker-класс, ядро чартера C1** |
| D4b term-клинч (:2600→:2601, :2682→:2683) | D5 шаги 2–3 (silent board-route fail → безусловный `sset term 1`) | Один и тот же баг; B локализовал оба сайта. C1 |
| D5 false-idle (:543 `_loop_is_alive`) | E2 (false-idle через `board review-leaves 2>/dev/null \|\| true`) | Два входа одного класса — чинить оба. C1 |
| D7 leaf status-divergence | E8-примечание (#1297 in-progress→review умер в шторме) | C1 (реконсиляция label vs run-state) |
| D8 reviewer-misclass (:2157 без role-check) | D3 review-stale + **jq role getter в board-gh.sh всегда отдаёт executor** | **Ключевая связка:** фикс D8 «ветка по role» БЕЗ фикса jq-геттера не сработает — геттер слеп. Оба в C2 |
| D9 double-zero bomb (test:349) | D2 finale-hygiene-test-unconditionally-red | Один баг; A добавляет: чинить некому in-loop → операторская рука (Фаза 0) |
| D10 deploy gap (хотпатчи под затирание) | A-тема (phantom rollout-листья) + постскриптум | **Подтвердилось вживую:** полный деплой 07-03 затёр token-split — восстановлен из бэкапа. Коррекции правил — §2 |
| D11 `grep -c \|\| echo 0` в 100+ тестах | — (A не сканировала тесты main) | Новое от B → в линт-скоуп C1 |
| D12 runtime вне линта | — | Новое от B → C1 (regression-lock класса D3) |

**Что A добавляет сверх B:** phantom-деплои (#1306/#1332) и слепой doctor; неэнфорсимый human-approval (110-секундный автомерж #1301) и проигнорированные security-blocking условия; finale-шторм (2571/5299 ретраев) и таксономия hold; план-черн (3×5 листьев); seccomp/visual-gate/baseline-red среда исполнителей; keepalive/мосты; REFUTED-мифы (ручные аппрувы; stale-owner URLs).

**Коррекции к Корзине C фактуры B** (устарело после деплоя 07-03):
- «НИКОГДА deploy-runtime.sh» → **скорректировано:** полный деплой валиден с quiesce-рецептом (стоп keepalive.timer → kill_switch → чистый выход → deploy → units → рестарт; проверен 07-03, field-test PASS). `deploy-live-swap.sh` на боксе по-прежнему ОТСУТСТВУЕТ (не в манифесте) и на этом боксе неработоспособен (tick-probe читает никем не писанный `run/tick.count`); юнит `crewboss-launcher.service` теперь установлен.
- «Роли осиротеют при full-deploy» → не подтвердилось: deploy-runtime не трогает `team-selfbuild/` (но каталог ролей ВНЕ деплой-пути — дыра остаётся, → C5).
- «Token-split слетит» → подтвердилось; восстановлен; до посадки в main — обязательный пост-шаг каждого деплоя.
- CB_IDLE_CONFIRM=2, CB_REVIEW_STALE_TICKS=10 — дефолты, не переопределены (оговорка (c) закрыта).

## 2. Состояние на 2026-07-03 ~07:00Z

- **Live на боксе:** весь main (78 файлов + smoke-runner + units): RL guard v2 + gh-shim, env-fail classify, triage-retry, rework-hygiene, watchdog #1142, approve-gate #1220. Петля под systemd (`journalctl -u crewboss-launcher`), keepalive-watchdog реально работает.
- **Латентно в задеплоенном main (рванёт под RL):** D3/D4b/D5/D7/D8 + мёртвая диета D1 — деплой их НЕ лечит, они В main.
- **Unmerged:** charter/1291 (finale-hygiene + role guard + taxonomy) — дедлок на #1333.
- **Очередь:** стоит, head=#1291, мёртвый спин с 01:11Z.

### Апдейт ~09:15Z — Фаза 0 ИСПОЛНЕНА (пункты выше описывают состояние до неё)

- 0.1 ✅ double-zero фикс (2654e26, сьют 24/0/0 на боксе) → #1333 закрыт → finale сам смержил **charter/1291 → main (PR #1338, 08:02:03Z)**; по пути гейт вскрыл и второй baseline-red — `ui-api-contract` (экстрактор слеп к `CMD_*`-константам, G5) — починен на main (77de2df, 25/0). Второй полный деплой сделан: finale-hygiene/role-guard/taxonomy-линт **live на боксе**.
- 0.2 ✅ token-split канонизирован в main (0e981e2) + manifest sha-lock + задеплоен — пост-шаг «ре-эплай» упразднён.
- 0.3 ✅ #306 закрыт not planned (лейблы сняты, прецедент #291).
- 0.4 ✅ P4-запись #1339 (создана и закрыта — рецепт и статус на борде).
- 0.5 ✅ чекпойнты: `run/rl_state` пишется gh-shim'ом (08:53Z, первая jail-сессия) — dual-pool guard полностью живой; тики в journald.
- Фаза 1 запущена: **C1 = #1341, C2 = #1346**, очередь `[1341, 1346]`; петля сама ведёт C1 (analysis + review-раунды с ~08:50Z). Известный риск: финал-ревью лифы C1/C2 могут упереться в review-stale ловушку (класс чинит сам C2) — разруливать рукой по рецепту #1333.

### Апдейт ~09:50Z — адверсариальный аудит вскрыл АКТИВНЫЙ P0 (Фаза 0 НЕ была flawless)

4-агентный read-only аудит (repo/box/board/liveloop) против заявления «всё безупречно» нашёл **работающую fork-бомбу**, не устранённые деплоем латентные баги main — и один из них активировался:

- **P0 fork-bomb в gh-shim (введён деплоем #1274, активировался при первой jail-сессии).** Шим вайрится в PATH джейла как символическая ссылка `/cbnet/gh → gh-shim.sh`. `_gh_shim_real()` резолвил символические ссылки для СВОЕГО пути, но кандидата из PATH только dir-резолвил (`cd -P dirname`), поэтому `/cbnet/gh` ≠ `/cbnet/gh-shim.sh` → шим выбирал сам себя как «настоящий gh» → `"$real" "$@"` рекурсировал без предела. Наблюдалось: 12 764 процесса, cgroup лончера упёрся в TasksMax=18854, `status=254` краш-рестарт-цикл каждые ~35 мин, и **три infra-смерти, ложно заблокировавшие C1 #1341** (ирония: ровно класс, который C1 и должен лечить). **Устранено:** `_gh_shim_resolve()` симметрично резолвит символические ссылки для self И кандидата (commit b65f977) + пояс `--env CB_GH_REAL=/usr/bin/gh` в spawn (PATH-walk становится moot) + regression-тест `gh-shim-resolve.test.sh` (воспроизводит символическую ссылку; фикс 3/3 pass, старый шим 3/3 fail — не тавтология). Задеплоено; подтверждено вживую: реальный gh 2.93.0 через символическую ссылку без рекурсии, TasksCurrent 44-46 (было 18854), rl_state обновляется jail-gh'ом, 0 fork/core-dump ошибок. #1341 сброшен (state + двойной label status:blocked/status:team-review → один team-review) и пере-спавнен чисто (review round 1).
- **Урок:** это ровно D12 из досье (runtime-скрипты вне линта, тесты не покрывали шим) — баг прошёл ревью и деплой, потому что не было ни одного теста на резолвер шима. Regression-тест добавлен; систематический runtime-линт остаётся в скоупе C1-P4.
- **Побочка:** fork-bomb выжег GraphQL-пул токена (user 35860020) до 0 (~09:50Z); восстановление — часовое окно, RL-guard v2 (уже live) держит петлю в backoff вместо false-idle. Core здоров (4997).
- Остаточные не-P0 находки аудита (в скоуп будущих чартеров/hygiene): #1341 double-status-label при blocked-переходе — класс C2 (blocked-transition должен стрипать stage-label); deploy-runtime.sh не стартует лончер (7-мин безпетельное окно после деплоя 08:04, keepalive вылечил) → deploy-рецепт уже требует явный `systemctl start` + verify-tick; `CB_PLAN_CONVERGE_CAP` doc/code рассинхрон (комментарий 4, код 6); keepalive-лог в `run/keepalive.out`, не journald; смерженная ветка charter/1291 удалена; #306 progress-лейблы — снять при восстановлении GraphQL (C7).

## 3. Стратегия

### Фаза 0 — руки оператора (сегодня, минуты–часы; петля тут бессильна)

1. **unblock-1291:** однострочный фикс `finale-hygiene.test.sh:349` (`| tail -n1` к `grep -c`) прямо на charter/1291 → снять `status:blocked` с #1333 → петля сама: финальный вердикт → finale → merge. После merge — доставка landed-файлов на бокс (quiesce-рецепт). Это разблокирует очередь и закрывает finale-шторм-класс + role guard.
2. **token-split в main:** PR на 3 строки (env-gated `CB_SESSION_GH_TOKEN` перед `GHENV=` в crewboss-spawn.sh; байт-в-байт при пустой переменной) — снимает вечный пост-шаг деплоя.
3. **Решение по #306:** close as not planned (как #291) или recycle — единственный undecided-зомби; пока ветки нет, шторм спит, restore ветки = ре-детонация.
4. **P4 sub-issue** (token separation) — открыть руками tech-lead из body PR #1309 (executor был capability-gated).
5. Поставить в очередь чартеры Фазы 1.

### Фаза 1 — P0-чартеры (через петлю, СЕРИЙНО — оба режут launcher)

- **C1 loop-honesty-under-RL** [B: чартеры 1+2+5; A: D5/E2/E5/E6]. Three-state gh-reads (agreed / not-agreed / **read-failed→retry**, cap не сжигается) на :1796/:1775/:1640 и всём цензе D3; write-фейлы громкие, `sset term 1` только после подтверждённой записи в борд (:2600/:2682) + term-reconcile watchdog; `_loop_is_alive`/idle-exit только на УСПЕШНОМ чтении борда (:543 + review-leaves путь); реконсиляция label↔run-state (D7); линт анти-паттернов на `reference/runtime/*` + тестовый ценз D11 (regression-lock). Acceptance: симуляция 403/пустого чтения → петля не роутит, не выходит, не term'ит.
- **C2 final-review-lifecycle + queue-defer** [B: чартер 3; A: тема D]. Сначала фикс jq role getter в board-gh.sh (иначе всё role-aware слепо); reviewer-ветка в :2157 (verdict-consumption по образцу triage-парсера, review-stale exemption для comment-only лифов); queue park на blocked-head ≥N тиков (status:hold + громкий коммент + pop) + `_stall_check` учит «blocked-work-only = stall»; idle-backoff. Acceptance: reviewer-лист с вердиктом закрывается сам; заблокированный head не морозит очередь.

Почему первыми: все остальные чартеры едут через эту же петлю — без C1/C2 они наткнутся на те же клинчи и ложные ревью-стейлы, что съели ночь.

### Фаза 2 — P1 (после C1/C2)

- **C3 enforce-approval-gates** [A: тема B]: machine-enforced `oversight:human` (integrator hard-skip до операторского approve), plan-stage FAIL на prose-only гейты, blocking security-находки → RED-тест/лейбл, реализация F4/F5/F6 (CB_GH_REAL pin, scoped bind вместо blanket run/, empty-PATH), аудит прошлых байпасов. Связка с #1220 P2.
- **C4 rl-hardening-v3** [B: чартеры 4+6; A: тема E остаток]: подключить GQL-диету во все label-read/write пути, acceptance = live-замер вызовов/тик до/после → **разблокирует откат CB_POLL**; api.py кэш/TTL finale-PR + вывод gh через shim; format-гейт fetch-fail ≠ parse-fail + конкретика инварианта (span_max); 5xx = retryable infra; RL-state-file verify в doctor.

### Фаза 3 — P2 (порядок по боли)

- **C5 deploy-is-an-act** [A: тема A]: box-observable acceptance rollout-лифов (sha С бокса == manifest + deploy-log в issue), integrator отказывает в закрытии без deploy-report, doctor behind-main probe → ops:alert, manifest completeness (smoke-runner, deploy-live-swap, composition-parse, каталог ролей), починить/выкинуть deploy-live-swap (tick-probe), GC .bak/zombie-мусора.
- **C6 executor-environment** [A: тема G]: seccomp `gh pr create` (вернуть RL-floor/supersede, которые агенты теряют на workaround), visual gate (podman + sentinel expiry), baseline reds (env-scrub, extractor), api `sh()` surfacing + degraded-флаг, re-adjudicate op, mandatory RED_REASON, разглушить спавн-вывод.
- **C7 plan-and-board-hygiene** [A: тема F]: минтинг листьев после plan:agreed / reuse, `--reason not-planned` + supersede-коммент, span_max-конкретика + согласование с рубрикой, close-leaf label-strips + терминальный статус + one-off sweep, orphaned-PR GC, plan-time verb/label capability check.
- **C8 supervision-nets** [A: тема H]: nohup-fallback lock fd CLOEXEC, relaunch-rate cap, инвентаризация aux-демонов (auto-unblock мост — ретайр или systemd-timer), doctor freshness-чек, live-верификация `_stall_check`.

### Правила исполнения (сквозные, из уроков обеих фактур)

1. Acceptance инфра-чартеров — только по наблюдаемому эффекту на живой системе; «зелёные стаб-тесты ≠ рабочая фича».
2. После КАЖДОГО landed чартера — деплой по проверенному рецепту (см. crewboss-deploy-process; до Фазы 0.2 — с ре-эплаем token-split) и live-чекпойнт. Не копить merged-but-not-deployed.
3. C1 и C2 — серийно (blast-radius на launcher); C3/C4 можно параллелить между собой; Фаза 3 — по одному.
4. CB_POLL=120 держится до C4-замера.

## 4. Чекпойнты первого активного окна (после Фазы 0.1)

- `~/cbnet/run/rl_state` появился после первой jail-сессии; в rl-guard строках лаунчера — ОБА пула (core+graphql).
- Ни одного `idle — run complete` при непустой очереди (D5), ни одного term-клинча (label↔run-state), review-stale только на PR-листах (D8) — до C1/C2 эти классы ЖИВЫ в задеплоенном main: любое срабатывание = ожидаемое, лечится руками по рецептам из [gh-rate-limit памяти], эскалировать не надо.
- Лог петли — `journalctl -u crewboss-launcher` (launcher.out юнитом больше не пишется).
