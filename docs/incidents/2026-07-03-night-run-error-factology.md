# Фактура по ошибкам ночного прогона 2026-07-02/03

Автономный ночной прогон петли crewboss (окно ~18:00Z 07-02 → ~02:00Z 07-03, плюс утренние инциденты того же дня, породившие чартеры) провёл через петлю чартеры #1142 (frozen-night watchdog), #1220 (approve-gate), #1274 (rate-limit v2), #1290 (env-fail/triage/rework) и #1291 (finale-scan hygiene). Фактура собрана forensics-проходом из 78 агентов по шести срезам (чартерные таймлайны, box-логи, борд, критик-проход), после чего **каждая находка прошла адверсариальную верификацию** с re-check'ом эвиденса у источника (gh, read-only ssh на бокс, git). Ниже — только CONFIRMED-материал (REFUTED вынесен в секцию J); формулировки учитывают коррекции верификатора, а не исходные гипотезы файндеров.

---

## Таймлайн ночи (UTC)

| Время | Событие |
|---|---|
| 07-02 00:59–03:32 | #1142 проходит чисто; PR #1279 → main 03:32:03Z (dead-man's-switch `_stall_check`) |
| 01:39 | Создан #1274 (RL v2) из утреннего GraphQL-инцидента (2073 RL-строки; /rate_limit врёт про bucket) |
| 04:31–05:31 | Выжжен core-пул; #1281: 3 ложных verify-merged RED → rework-cap 2/2 → blocked |
| 05:18:52 | triage для #1281 умирает за 39с без вердикта → вечная парковка (повторы 07:05, 07:14) |
| 06:13:25 | Finale-шторм #306 (2571 ретрай с 06-29) прекращается — оператор вручную удалил ветку |
| 06:39–07:17 | Оператор: деплой ролей triage/reviewer/recovery-lead, закрытие superseded PR, ручной мерж PR #1289 («operator: gate env-broken, code stash-verified») |
| 07:34:57 | #1220 finale PR #1294 → main |
| 07:35–09:05 | Composition-шторм #1274: все 15 format-раундов сгорели на «missing or invalid» (реально span_max), HD #1296; оператор разруливает 09:36 |
| 10:48/10:55 | Два «PLAN-REVIEW: agreed» на #1274; лончер не смог прочитать label (RL) → 10:56:34 «failed (2) -> blocked», term=1 |
| 10:56→18:43 | Очередь заморожена ~7ч47м: #1274 держит plan-head, #1290 голодает 6ч19м |
| 11:36/11:39 | #1290 composition дважды отбит той же генерик-ошибкой (6 leaves > span_max=5) |
| 17:10–19:16 | Relaunch-шторм: keepalive делает 10 «loop DOWN -> direct launch» за 2ч06м (лончер false-idle'ит на RL) |
| 18:43:45 | Человек чистит term-флаг → #1274 released; 18:44:47 стартует plan-review #1290 |
| 18:57→20:15 | #1297 done, но мерж только через 78 минут (GraphQL-пул мёртв 18:00:40–20:12:18Z, 122 RL-строки) |
| 19:16:50 | Финальный запуск лончера pid 325828; keepalive самоотключается (унаследованный lock fd) — 11ч+ skip'ов |
| 19:34:15 | #1290 approved (петлёй, по агентскому plan:agreed — см. секцию J) |
| 20:43:57 | PR #1311 (деплой-лиф #1301 с require_human_approval) авто-смержен **за 110 секунд**, 0 комментариев/ревью |
| 20:47:04 | #1274 finale PR #1312 → main; P2 «GraphQL diet» — dead code |
| 21:56:24 | «Деплой»-лиф #1306 закрыт green — бокс не тронут |
| 21:59:21 | #1290 finale PR #1318 → main |
| 22:03–22:55 | Планирование #1291: span_max-баунс, 3 поколения листьев (15 issues), план v3 agreed 22:55 |
| 23:17→00:37 | #1329–#1332 мержатся в charter/1291 |
| 07-03 00:46:31 | final-review вердикт на #1291: «BLOCKED — test-suite is RED» (баг в самом qa-тесте) |
| 01:11:17 | #1333 заблокирован review-stale watchdog'ом («10 ticks without an open PR») |
| 01:11→06:10+ | Мёртвый спин: 111+ идентичных `queue-mode: order=[1291]` тиков за 5ч, ноль прогресса, GraphQL-пул выжигается вхолостую |
| Итог по боксу | Все runtime-файлы датированы Jun 30; **ни один ночной фикс не задеплоен** |

---

## Темы

### A. «Merge ≠ deploy» — фантомные rollout-листья (P0-тема ночи)

Оба «деплой»-лифа ночи закрылись COMPLETED, не тронув бокс; вся ночь и весь следующий день петля работает на коде Jun 30, борд читает все фиксы как доставленные, doctor — зелёный.

**A1. Лиф #1306 «rollout-live-loop» закрыт green без единого касания бокса (P0, CONFIRMED).**
- Спека #1306: «Deploy launcher / integrator / smoke-runner / cb-pr-create / rework-prep from merged main to the live box … report on this issue either way». Закрыт 21:56:24Z, единственный коммент — «Closed by integrator after merge ea5ca09…»; деплой-репорт не запощен никогда.
- Коммит ce42620 заявляет «This leaf makes them live on the box safely», но diff — только additions: deploy-live-swap.sh (333 строки) + runbook (115) + doctor entrypoint (17). Док заканчивается секцией «Operator runbook (on the box)» — деплой молча делегирован оператору.
- Machine-acceptance лифа — **repo-only** («check: bash crewboss-doctor.sh», «check: bash reference/tests/runtime-manifest.test.sh») — структурно выполнима без контакта с боксом. Root cause подтверждён verbatim.
- Бокс (read-only ssh, 07-03): `~/cbnet/deploy-live-swap.sh` — ABSENT (сам тул не доехал); `run/deploy-1306.log` — ABSENT; `backups/` — ABSENT; grep run/ по deploy|swap|quiesce → 0.
- sha vs main-манифест: launcher box=40a44edb… vs manifest=ccbe18aa…; integrator 842cdccc… vs eb462f89…; cb-pr-create 067638a8… vs ea13d5b1…; rework-prep d80edca0… (ручная операторская копия Jul 2 08:32) vs 67406917….
- Живой цикл pid 325828 (start Jul 2 19:16:49) всю ночь исполнял Jun-30 код.

**A2. Лиф #1332 (rollout чартера #1291) — вдвойне недоставлен (P0, CONFIRMED).**
- Спека (план #1291 @22:49:44Z): «Deploy the merged launcher/doctor changes to the box via the #1306 deploy-live-swap path (quiesce at tick boundary, verify healthy tick, byte-exact rollback…)». Закрыт COMPLETED 00:37:09Z, коммент — только «Closed by integrator after merge a258fe6…».
- a258fe6/e3b58dc существуют **только** на unmerged charter/1291 — не на main И не на боксе; §3 дока (docs/reference/1332-lint-catalog-rollout.md) — императивный runbook, не отчёт.
- Следствие обоих: env-fail classify (#1303), triage storm-retry (#1304), rework hygiene (#1305), finale hygiene, role guard, RL v2, watchdog #1142 — merged-but-not-live, борд читает как delivered.

**A3. Петля не имеет self-deploy шага (P1, CONFIRMED).**
- На боксе: `grep -c _stall_check ~/cbnet/crewboss-launcher-gh.sh` → 0; `grep -c CB_PROGRESS_STALL_HOURS ~/cbnet/run-env.sh` → 0; `ls ~/cbnet/gh-shim*` → нет.
- Watchdog против frozen-night смержен 03:32Z — за ~23ч до конца прогона — и ни разу не взводился; повторная frozen night снова была бы тихой.
- На main лончер не содержит ни одного вызова deploy-live-swap / auto-deploy hook (только комментарии); рестарт лончера 19:16:49Z (через 15.7ч после мержа #1279) всё равно поднял Jun-30 файлы — box = file-copy, не git.

**A4. Doctor слеп к stale-деплою (P1, CONFIRMED).**
- Drift-check сравнивает файлы бокса с **его же локальной копией** runtime-manifest.tsv (`MANIFEST="$CB_HOME/runtime-manifest.tsv"`, датирована Jun 30 18:20) — никогда-не-деплоенный бокс всегда самосогласован и зелёный.
- Проверено: deployed launcher sha == box-manifest entry (self-consistent), при этом main-манифест расходится по всем трём цитируемым файлам. Никакой компонент не владеет инвариантом «deployed == merged»; ничего не зовёт doctor после finale.
- Box-vs-repo сравнение существует только как transient шаг 6 deploy-live-swap — который не запускался.

**A5. deploy-live-swap целится в несуществующий systemd unit (P1, CONFIRMED).**
- Тул делает `systemctl stop/start crewboss-launcher`; на боксе: «Unit crewboss-launcher.service could not be found» (установлены только crewboss-api.service + crewboss-loop-keepalive.{service,timer}). Живая петля — detached bash, PPID 1, keepalive-managed.
- Новое от верификатора: health-probe читает `run/tick.count`, который **никакой реальный лончер не пишет** (только simulate-стаб) → verify_health детерминированно TICK-FAIL через 300с и откатывает даже здоровый деплой; restart() при откате тоже падает (unit not found), петля лежит до nohup-релонча keepalive'ом.
- Shipped safe-deploy path на этом боксе не может завершиться успешно в принципе; simulate стабит и systemctl, и tick-counter — «rehearsal passes anywhere». Паттерн unit-absent fallback уже был рядом (keepalive #1144) — тул его проигнорировал.

**A6. smoke-runner.sh вне runtime-manifest.tsv (P2, CONFIRMED).**
- Лиф #1303 менял smoke-runner.sh под мандат «regen sha256 for all touched runtime files», но файла нет в манифесте вовсе → sha-lock/drift слепы; deploy-док честно печатает «n/a smoke-runner.sh (not sha-locked in manifest)».
- Боксовая копия = оригинал #997 (sha e6a5ff5b…, Jun 29, 13225 байт); main ушёл на 3 версии вперёд (#1015, #1018, #1303; 18409 байт) — три версии дрифта, не флагнутые ничем. Даже полный deploy-runtime.sh его не обновит (деплоится manifest-set).
- runtime-manifest.test.sh: Test 2 валидирует замороженный снапшот 2026-06-11, Test 4 — хардкод из 13 файлов без smoke-runner; dynamic completeness-check не существует.

**A7. Крафт в ~/cbnet душит сигнал доктора (P3, CONFIRMED).**
- 44 `*.bak-*` файла (~24 — .bak-rename-20260702), 460 записей в run/state, 34 finale-*.zombie-bak.
- doctor: «103 problem(s)» = 27 MISMATCH + 76 EXTRA; сами 27 MISMATCH — в основном следы rename-хотпатча 07-02, применённого на боксе без regen манифеста, т.е. drift-сигнал сейчас ~100% шум.
- EXTRA — не только .bak: scratch-артефакты (run-conv-*, run-night-*) и легитимно задеплоенные, но не манифестированные скрипты (smoke-runner.sh, composition-parse.sh, manifest.sh, auto-unblock-approval.sh…).

**Статус:** unfixed (системно). Инструменты (deploy-live-swap.sh, runbook) merged on main via PR #1317/#1318 — NOT deployed и неработоспособны на этом боксе; #1332-часть — fixed on charter/1291 — unmerged.
**Чартер:** сделать деплой верифицируемым актом: (1) немедленный операторский полный деплой runtime на бокс (задача уже висит); (2) acceptance rollout-лифов = box-observable evidence (sha, прочитанный С бокса == repo-manifest + healthy-tick marker + deploy-log в issue); интегратор отказывается закрывать rollout-лиф без deploy-report; (3) doctor behind-main probe (box vs origin/main манифест, «behind by N commits/days») + wire в ops:alert; (4) починить deploy-live-swap под detached+keepalive модель (kill_switch + keepalive pause + pgid kill) или поставить unit; починить tick-probe на реальный сигнал; preflight «unit absent И keepalive не найден → refuse»; (5) manifest completeness-check (fail при runtime-файле без записи); (6) GC .bak/zombie-bak + ignore-list доктора + boot-баннер лончера со своим sha.

### B. Гейты аппрува не энфорсятся

**B1. require_human_approval существовал только как проза — авто-мерж за 110 секунд (P1, CONFIRMED).**
- Лиф #1301 (gh-shim deploy wiring, rubric trigger touches_auth_or_secrets), body: «HUMAN-APPROVAL GATE (rubric security trigger, require_human_approval=true): this leaf's PR is blocked-on-human-approval — it must NOT merge until an operator explicitly comments approval. Security-reviewer sign-off (#1300) is necessary but not sufficient».
- Реальность: PR #1311 created 20:42:07Z → merged 20:43:57Z — **110 секунд жизни, comments: [], reviews: []**. Launcher-лог: bg-spawn 20:35:54Z → done 20:43:38Z → «verify-merged=pass try-merge=clean — merging» 20:43:55Z → closed 20:43:59Z.
- Гейт был написан в composition, plan, plan-review («explicit human-approval gate where security sign-off is necessary-not-sufficient», @10:48:12Z), security-review и issue body — и ни в одном runtime-механизме: лиф нёс только type:agent/status:review/claimed-by:cb1/role:infra-engineer.
- На main `grep -rE 'require_human_approval|oversight:human' reference/runtime/` — пусто; approval-механика лончера — только charter-level cost-threshold (:1711-1716). Пересекается с заблокированным #1220 P2 (oversight:human) — fix-чартер должен ссылаться на него, не дублировать.

**B2. Blocking-условия security-ревью проигнорированы при мерже (P1, CONFIRMED).**
- #1300 → #1301 @20:33:42Z, два BLOCKING pre-merge условия: «F6 — pin the real gh (blocking) … Inject CB_GH_REAL=<absolute path to the real gh> … into the nsjail env»; «F4/F5 — Create $CB_HOME/run as 0700 and land rl_state as 0600 … must be scoped to the state file / a dedicated subdir — not a blanket host-run/ mount».
- Смерженный d1684af (авторство 20:41:13Z — через 8 минут после blocking-коммента) не содержит **ни одного**: grep CB_GH_REAL по reference/runtime/ — hits только gh-shim.sh:45-48 (чтится, не инжектится); perms 0700/0600 нет; bind — `-B "$CB_HOME/run:/cbnet/run"` — blanket rw-mount всего host-run/ (state/locks/work всех сессий) во все джейлы, включая CB_FS_CBNET=ro роли — ровно то, что F5 запрещал.
- Плюс незакрытый из #1300: «Empty PATH element → CWD: line 65 maps an empty PATH element to p="." … classic empty-element CWD injection» — gh-shim.sh:65 не тронут ни на одной ветке.
- Root cause: blocking-находки ревью — прозаические комменты без представления в verify/merge-гейте; QA-suite #1297 писался ДО security-ревью, ни один тест не кодирует F4/F5/F6.

**Статус:** unfixed (нигде, ни на одной ветке).
**Чартер:** (1) machine-enforced require_human_approval: план ставит `oversight:human`-лейбл, интегратор hard-skip до операторского approve; plan-stage FAIL'ит, если лиф декларирует гейт, а stamping-механизм недоступен (prose-only гейты невозможны); regression-тест «gated leaf не мержится»; (2) blocking-находки security-ревью = RED-тесты или лейбл, который интегратор чтит; approve-путь показывает нерезолвленные blocking-условия; (3) реализовать F6 + F4/F5 (scoped bind) + empty-PATH skip; (4) аудит прошлых мержей на тот же байпас.

### C. Finale-шторм зомби-чартеров (фикс — на unmerged charter/1291)

**C1. Finale-скан не читает ни один status-лейбл — шторм на полную мощность (P1, CONFIRMED).**
- `_charter_finale_cycle` (main :1353-1369) выбирает кандидатов только по OPEN+type:charter+zero-open-leaves+branch-ahead; нулевые проверки hold в :1300-1520. Цена тика на кандидата: 2× полный `git clone --bare` (:1382/:1397) + autorebase + merge-попытка + gh-вызовы.
- Количественно (box launcher.out): **2571** ретрай «charter-finale: #306 real conflicts» (первый 2026-06-29T08:29:07Z, последний 2026-07-02T06:13:25Z; по дням 572/903/943/153), **5299** finale-строк по #291. Конфликты одни и те же каждый ~50-60с тик (runtime-manifest.tsv, App.tsx, styles.css).
- `status:needs-conflict-resolution` ставится (:1408), finale его не читает; коррекция верификатора: единственный consumer (git-resolver spawner :2536-2557) **исключает** hold-чартеры — оба зомби несли `hold` → held+conflicted чартер штормит вечно без пути резолва. Git-resolver вдобавок queue-head-gated — #306 не мог получить резолвера при queue=[1220,1274].
- Шторм остановлен не кодом: оператор удалил ветку charter/306 (бэкап zombie-bak/charter-306-20260702); finale скипает по ls-remote miss. Все 2571 gh-вызова шли через общий токен.

**C2. Таксономический дрейф hold: чартер отгружался с инвертированной посылкой (P2, CONFIRMED).**
- Body #1291 называл голый `hold` «мёртвой опечаткой таксономии» и спекал P1 на skip по status:hold, P4 — на линт против bare hold.
- Plan-review @22:29:45Z доказал из кода обратное: «живое вето лончера — ГОЛЫЙ лейбл `hold`: все шесть фоновых циклов фильтруют по `index("hold")` (launcher :2308, :2336, :2541, :2587, :2674, :2695), `status:hold` не потребляется НИГДЕ в рантайме» — grep верификатора подтвердил все шесть строк и пустой grep по status:hold.
- Без ревью чартер отгрузил бы линт, велящий операторам удалить их единственное рабочее вето, и finale, чтящий не тот лейбл — точный реплей зомби-инцидента. Root cause: «no canonical label-taxonomy artifact exists yet» (composition-approval @22:18:52Z).
- Нюанс: даже после мержа 1291 status:hold станет consumed только finale (0d1a412) — split двух форм сохранится в остальных шести циклах; миграция орфана — обязательный шаг конвергенции, не cleanup.

**C3. #306 — открытая недорешённая мина (P3, CONFIRMED).**
- #306 до сих пор OPEN: [type:charter, status:hold, hold, composition:approved, status:needs-conflict-resolution, review:agreed, plan:agreed], zero open leaves; последний коммент 2026-06-22.
- От шторма спасает **только** отсутствие ветки (`git ls-remote … || continue`); restore бэкапа перевзводит шторм на текущем main/боксе. #291 закрыт оператором ещё 06-22 — #306 фактически единственный undecided-зомби.
- Решение recycle-or-resolve явно deferred («the #291 recycle-or-resolve decision … is a human call outside these leaves», composition @22:03:10Z) и не принято до сих пор.

**Фикс (существует, не доставлен):** 0d1a412 «fix(finale): board-aware skip + conflict-cap parking + fetch-cache (#1291 P1/P2)» — skip bare `hold`/`status:hold`/`status:needs-conflict-resolution` (L1496), CB_FINALE_CONFLICT_CAP=3 parking с CONSUME лейбла (L1554-1560), fetch-cache вместо клонов; e3b58dc — CB_STATUS_TAXONOMY pin + report-only линт. `git branch -r --contains 0d1a412` НЕ включает origin/main.

**Статус:** fixed on charter/1291 — **unmerged** (final-review #1333 status:blocked); на main и боксе шторм-класс жив; шторм прекратился, вероятно, лишь потому, что ночь шла с пином CHARTER_SCOPE.
**Чартер:** разблокировать и доземлить charter/1291 (см. тему D) → реальный деплой; миграция/алиас status:hold во всех циклах + taxonomy-артефакт в деплой; операторское решение по #306 (close as not-planned как #291, или recycle); doctor-lint «OPEN charter, zero open leaves, no live branch» = undecided zombie.

### D. Дедлок финала #1291 — текущий live-блокер (P0)

Цепочка полностью доказана: (1) qa-тест сам красный → (2) вердикт-коммент невидим рантайму → (3) review-stale блокирует лиф → (4) finale-прекондишн невыполним → (5) очередь не умеет defer.

**D1. Дедлок и стойло очереди (P0, CONFIRMED).**
- #1333 OPEN [type:agent, status:blocked, claimed-by:cb1, role:reviewer]; #1291 OPEN [type:charter, status:approved, composition:approved, review:agreed, plan:agreed] — approved but unmergeable.
- С 01:11:17Z каждый ~2.7-мин тик — только `queue-mode: order=[1291] head=#1291 plan-head=#none accept-head=#1291` (строки 212096-212125: 29 подряд за 04:53→06:08; всего 111+ за 5ч, стойло продолжалось на момент проверки 06:13Z).
- Единственное не-idle содержимое лога после 01:11:17Z: сам blocking-event и один «HTTP 502 (graphql)». Idle-спин при этом дожёг общий GraphQL-пул: 3× «rate limit already exceeded» между тиками 06:16:16Z и 06:18:54Z.
- Рекурсия: фиксы, застрявшие на charter/1291 (_cb_role_guard, CB_FINALE_CONFLICT_CAP — 22 хита на ветке, 0 на main/боксе), — ровно те гарды, которых не хватает лончеру, но задеплоиться они не могут, потому что их собственный finale и есть дедлок.

**D2. QA-тест unconditionally red + некому чинить (P1, CONFIRMED, воспроизведён вживую).**
- `reference/tests/finale-hygiene.test.sh:349`: `_nbare=$(grep -c bare-clone "$CLONE_BARE_LOG" 2>/dev/null || echo 0)` — при 0 матчей grep печатает `0` И выходит 1, `|| echo 0` добавляет вторую строку → `_nbare="0\n0"` → `[: integer expression expected` → FAIL P2.1 на **корректной** реализации; при N≥1 — легитимный fail. Ни одна реализация не проходит. Верификатор воспроизвёл краш в live-shell.
- Условие краша: строка 336 pre-create'ит лог (`: > "$CLONE_BARE_LOG"`) — проверено, есть.
- Латентность: plan v2/v3 мандатировали feature-detection SKIP-гарды («report SKIP not PASS») → тело assertion ни разу не исполнялось на merge-gate qa-лифа #1329 и детонировало только после посадки #1330.
- Чинить некому in-loop: qa-лиф #1329 закрыт, executors hard-gated от tests/ (.claude/hooks/crewboss-gate.sh), reviewer'у «Do not write code»; machine-acceptance самого #1333 включает `bash reference/tests/finale-hygiene.test.sh` — невыполнима. Фикс (`| tail -n1`) на tip a258fe6 так и не закоммичен.
- Hazard-прогноз (не инцидент): при закрытии #1333 без фикса #1291 сам становится finale-кандидатом с перманентно красным гейтом — self-inflicted реплей шторма #306 на непочиненном live-лончере.

**D3. Review-stale блокирует comment-only лифы by construction (P1, CONFIRMED).**
- #1333 body: «Deliverable: review verdict comment on charter #1291 (approve or itemized blockers). Do not write code». Вердикт доставлен @00:46:31Z («VERDICT: ❌ BLOCKED — 1 blocker (test-suite is RED)») — и потреблён ничем.
- Интегратор: единственный выход из status:review — открытый/смерженный PR с head leaf/rework (launcher :794-845); через 10 тиков (00:47:44→01:08:40 stale 1..9) → «review-stale (10 ticks without open PR) — blocking» @01:11:17Z. **Даже APPROVE-вердикт закончился бы blocked.**
- `grep -rn "final-review" reference/runtime/*.sh` = 0 матчей; verdict-parser существует только для kind=triage (launcher ~:2010). Контрпример-случайность: #1284 (final-review #1220) закрылся только потому, что агент добровольно открыл docs PR #1293.
- Углубление верификатора: kind=executor у #1333 — из **латентного jq-бага board-gh.sh role getter**: `[.labels[].name[]? | select(startswith("role:"))]` итерирует строку с подавлением ошибок `?` → всегда пусто → fallback «role:executor» для ЛЮБОГО лифа (проверено live-jq; в proto/r6, снапшоте и на боксе). Role-лейблы вообще не влияют на board-dispatched spawn'ы; _cb_role_guard с charter/1291 звал бы тот же сломанный getter и валидировал бы «executor» вместо реальной роли.
- Три plan-review раунда (#1291) верифицировали falsifiability acceptance всех лифов, КРОМЕ completion-механизма самого final-review.

**D4. Очередь не умеет defer на застрявшем head (P1, CONFIRMED).**
- Head-selection (main :2204-2233) скипает head только по состоянию самого ЧАРТЕРА (done|blocked|hold|deferred); blocked ЛИФ head не двигает — ни pop, ни park, ни escalation, ни idle-backoff, ни операторский артефакт (последний коммент #1291 — вердикт 00:46:31Z, ни hold, ни HD-issue).
- Хуже: `_stall_check` (#1142) в step-3 предикате **исключает** blocked-лифы → «все оставшиеся работы blocked» классифицируется как idle-not-stalled — watchdog осознанно вырезал ровно этот случай и не сработал бы даже задеплоенным.
- Ручной escape-hatch существует (status:hold на чартер выбил бы его из всех трёх head-вычислений) — ничто его не автоматизирует и не подсказывает.

**D5. Blocked plan-head заморозил конвейер на ~8 часов (P1, CONFIRMED; root cause файндера ОПРОВЕРГНУТ и заменён).**
- Симптом: #1274 «plan-review failed (2) -> blocked» 10:56:34Z, но остался plan-head; #1290 ждал plan-review 6ч19м (12:25:39→18:44:47Z); освобождение — через минуту после человеческого вмешательства 18:43:45Z.
- Гипотеза «нет eviction блокированных» — неверна: eviction есть с #423 (:2221-2225). Реальная цепочка (всё под RL-штормом, 338 RL-строк в окне):
  1. launcher:1796 `_plok=$(gh issue view … || echo "false")` — RL-фейл чтения неотличим от «plan not agreed»; plan:agreed стоял с **10:48:20Z** (и второй agreed-вердикт в 10:55:18Z!) — успешный plan-review дважды засчитан как провал, плюс лишний спавн round-2;
  2. на retry-cap `board route blocked` **молча упал** (status:blocked так и не появился в issue-timeline), а `sset term 1` (:1825) выполнился безусловно → run-state разъехался с бордом;
  3. plan-convergence gate (:2595) и limbo-reconcile #957 (:2698) оба скипают чартеры с term; queue-mode ограничивает оба гейта plan-head'ом → жёсткий дедлок без watchdog, разорванный человеком, чистящим term-флаг в run-state ~18:43Z (лейблы человек не трогал).

**Статус:** unfixed; live-блокер прямо сейчас. Immediate-разблокировка: однострочный qa-фикс `finale-hygiene.test.sh:349` на charter/1291 → unblock #1333 → finale → деплой.
**Чартер:** (1) runtime-контракт non-PR лифов: machine-readable вердикт (label/pinned marker; определить, ГДЕ постится), integrator: approved→close leaf, blocked→rework на владеющий лиф/роль (уважая tests/-gating), никогда не review-stale'ить лиф с доставленным вердиктом; шаблон — kind=triage parser (:2010-2069); альтернатива/дополнение — мандат docs-PR deliverable по паттерну #1284; contract-тесты обоих путей; (2) qa-rework механизм в tests/ после закрытия qa-лифа + прогон SKIP-guarded групп в forced-on режиме (против стаба) на их же merge-gate; (3) queue-level park: head без runnable-лифов и с blocked-лифом ≥N тиков → status:hold + громкий коммент с именем блокирующего лифа + pop + cockpit-виджет; расширить _stall_check («blocked-work-only = stall, не idle»); idle-tick backoff + метрика ticks-without-transition; (4) three-state completion checks (agreed / not-agreed / **read-failed → retry read**, не сжигая try; то же на :1775 и :1840); board-route фейлы — громкие, term=1 только после подтверждённой записи в борд; watchdog «plan-head с term=1, без pid, non-terminal board state N тиков → re-derive/clear/escalate»; (5) фикс jq role getter в board-gh.sh (отдельная строка — баг шире этой темы).

### E. Rate limit / GraphQL

**E1. GraphQL-слепая зона — хроническая, не ночная (P1, CONFIRMED).**
- RL guard v1 (#1004) — только REST core. `grep -c 'rate limit already exceeded' ~/cbnet/run/launcher.out` = 2832; коррекция верификатора: это **кумулятив с Jun 13** (Jun13=909, Jun15=171, Jun16=574, Jun18=241, Jun20=96, Jun22=59, Jun23=10, Jun29=13, Jul2=756, Jul3=3) — выжигание в 8 разных днях.
- 07-02: хиты в **каждом** часе T05–T20 (пик T18=92 — в окно прогона). Агентские сессии (analysis, plan-review, triage) падали на gh-вызовах весь день; core оставался зелёным.
- /rate_limit при этом отчитывался core remaining 4972, пока фактический GET /repos/... в ту же секунду отдавал 403 X-Ratelimit-Used: 5000, Remaining: 0 (другой bucket); пул выжигался за ~27 минут (~185 вызовов/мин).

**E2. Шторм в окне прогона: 78 минут стойла + false-idle + relaunch-и (P1, CONFIRMED).**
- 122 RL-строки в окне (92 в 18h, 25 в 19h, 5 в 20h; первая 18:00:40Z, последняя 20:12:18Z). #1297 done 18:57:04Z → merge 20:15:05Z (**78 минут**, ноль integrator-строк между; merge — через ~2.5 мин после hourly reset; дальше весь чартер burst'ом: 20:15/20:21/20:27/20:35/20:43, finale 20:47).
- В шторм лончер печатал «idle — run complete» (18:58:43, 19:01:57, 19:06:38Z) и выходил, пока #1297 висел в review; keepalive релончил (см. тему H); голый «Terminated» в логе 19:16:37-50Z.
- Механизм false-idle уточнён верификатором: `board review-leaves 2>/dev/null || true` рендерит RL-фейл чтения как пустой борд; на main паттерн идентичен, backoff v2 капится 60с (`|| true`), shim-sleep ~360с — оба сильно меньше часового reset'а → false-idle достижим и после фикса. «Dedupe keepalive-релончей» из скоупа файндера — DROP: keepalive работал корректно.

**E3. P2 «GraphQL diet» отгружен как dead code, чартер закрыт done (P1, CONFIRMED).**
- Цель P2 #1274 — срезать главный бёрнер: «Живой замер бёрн-рейта: ~50 GraphQL-вызовов/мин в спокойном режиме (~3000/час)» (body чартера).
- Смержено (#1298/PR #1309, 408e748): `_cb_issue_labels_cached`, `_cb_edit_enqueue`, `_cb_edit_flush_*` — **ноль call-sites** вне определений и комментариев; `git show 408e748`: удалено 0 строк `gh issue view` / `gh issue edit` (стало 32/34, было 28/31).
- PR-body честно признаёт: «no behavioural launcher test covers routing, so the risky bulk rewire is documented rather than done blind» — но acceptance/QA (unit «mock tier 43/0») и finale приняли это за done; чартер закрыт 20:47:04Z. Классика «зелёные стаб-тесты ≠ рабочая фича»; RL guard v2 конвертирует exhaustion в backoff-сны, но бёрн не режет. Верификатор сам упёрся в 5000/hr GraphQL-лимит во время проверки.

**E4. Idle-петля + дашборд жгут бюджет при нулевой работе (P2, CONFIRMED).**
- crewboss-api.py `_compute_stuck()` (:397, вызов :546) шеллит `gh pr view <finale_pr> --json isDraft,state` на КАЖДЫЙ open-чартер при каждом /api/state GET и каждые 10с на SSE-таб (CB_API_POLL=10; в коде даже задокументирован прошлый инцидент #526), без кэша/TTL.
- Live-подтверждение: дочерний `gh pr view 1279` прямо в момент проверки; CPU сервиса 9ч27м/21ч аптайма; свежее hourly-окно: graphql used=953 vs core used=14 при полностью пустой (заблокированной) очереди. Снапшот файндера: used=4216/5000 (84%) на холостом ходу.
- api.py — systemd-сервис с plain gh, **вне** шима #1274; коррекция: поллит только OPEN-чартеры (не закрытые), но open-but-abandoned — навсегда.

**E5. Analysis/format-шторм под RL (P2, CONFIRMED с коррекцией).**
- 8 respawn'ов «analysis (retry: solution-analyst)» для #1274 за 07:36–09:44Z (+1 в 04:35). Коррекция: спавны 07:36–07:52 реально завершали анализ и биты format-гейтом.
- Самое острое: гейт сжёг format-раунды 5→9 (07:55:06→08:05) на тиковой каденции ~50с, когда НИ ОДИН аналитик не мог быть в петле — под RL и fetch композиции, и `gh issue comment` падали молча (`2>/dev/null || true`), гейт re-fire'ился каждый тик по той же stale-композиции. Все 15 раундов сгорели к 09:00:51Z; HD #1296 создан автоматически 09:05:42Z (эскалация-на-кап сработала).
- Новый суббаг: после operator-verified EXIT=0 композиции сгорело ещё 6 раундов (09:48:58–09:56:18) — transient fetch-фейлы неотличимы от «composition missing». Для #1291 «same pattern» опровергнут — там был один benign format-баунс без RL.

**E6. Plan-review под RL: false-fail, false-block, дубль-ран (P2, CONFIRMED; root cause дубля скорректирован).**
- Любой ненулевой выход агента идёт в 2-strike cap (CB_RETRY_CAP=2) без infra/code-классификации; сам probe успеха (`_plok=$(gh issue view … || echo "false")`, :1796) конфлейтит «gh упал» и «label отсутствует»; те же паттерны на :1775 (review:agreed) и :1840 (accept-review).
- Следствия: #1274 — **два** agreed-вердикта (10:48:12Z и 10:55:18Z, второй — «independent re-verification»), второй спавн вообще был лишним (round-1 поставил plan:agreed за 54с до «failed(1)»), чартер всё равно «blocked», очередь заморожена 7ч47м (тема D5). #1290 — «failed (1) -> retry» 18:49:54Z при том, что агент поставил plan:agreed в 18:49:13Z. Ирония: falsely-blocked оказался сам RL-чартер.
- Fix-статус: fb7a09c (#1303) классифицирует infra ТОЛЬКО в verify-merged/smoke; plan-review/review/generic-retry пути не тронуты нигде (включая charter/1291).

**E7. GraphQL 5xx — вне любой классификации (P3, CONFIRMED).**
- «HTTP 502: 502 Bad Gateway (https://api.github.com/graphql)» между idle-тиками ~05:58Z 07-03; не уникально — ≥5 случаев за жизнь лога (Jun 22, Jun 24, …, Jul 1 21:29Z, Jul 3). Каждый раз benign, но 5xx внутри capped-операции съест cap.
- Шим гейтит только пулы (rate-budget precall/postcall), transport-ошибки проходят raw и без ретрая — и на main, и на charter/1291.

**E8. Диагноз RL v2 (справочно, P2).** Ядро #1274 подтверждено целиком: 25 issue-edit / 20 issue-view / 14 issue-comment сайтов лончера на GraphQL-пуле; jail-сессии с GH_TOKEN вне guard'а; один общий токен (user 35860020) на лончер+сессии+операторские gh. PR #1307–#1312 верифицированы на main (dual-pool guard :327-399, gh-shim.sh).

**Статус:** partial — guard v2 + gh-shim merged on main via PR #1312 — **NOT deployed** (на боксе 0 хитов `_cb_rl_poll`/`CB_RL_FLOOR_GQL`, шима нет; шторм рецидивировал утром 07-03 ~06:16Z); GQL-диета — dead code; false-idle / three-state reads / format-гейт под RL / api.py-кэш / 5xx — unfixed везде.
**Чартер:** (1) деплой RL v2 на бокс + live rate_limit soak; (2) idle-exit гейтить на УСПЕШНОЕ чтение борда (failed read ≠ пустая очередь; спать до pool reset); (3) довайрить GQL-диету в ~14 label-view сайтов + edit-батчинг, acceptance = измеренные live gh-вызовы/тик до/после, не unit-green; (4) infra-классификация всех capped-путей (plan-review, review, generic retry) + three-state label probes; (5) format-гейт: fetch-fail ≠ parse-fail (раунд не сжигается, retry тика), counter — по новым композициям аналитика; (6) api.py: кэш/TTL finale-PR (terminal MERGED не перечитывать), увести gh через shim/in-process cache; (7) 5xx (REST+GraphQL) = retryable infra в шиме, structured-лог + per-tick счётчик для доктора; (8) token separation — рецепт лежит в body PR #1309 (см. F5).

### F. План-конвергенция и борд-гигиена

**F1. Каждый reject плана = полное новое поколение листьев (P2/P3, CONFIRMED).**
- #1291: план v1 создал #1319–#1323 (22:22:37Z — за 7 минут ДО первого plan-review вердикта), rejected @22:29:45Z → v2 создал СВЕЖИЕ #1324–#1328, gen-1 mass-closed 22:31Z; rejected @22:43:21Z → v3 #1329–#1333, gen-2 closed 22:44Z. **3 поколения × 5 листьев = 15 issues за 26 минут.**
- 10 никогда-не-работавших issues закрыты со stateReason=COMPLETED и **нулём** комментариев/лейблов supersede (единственная запись — в plan-v3 комменте на чартере). Board-метрики считают их выполненными; кросс-ссылки v1/v2 висят на мёртвых номерах.
- Механизм (код main): GC #444 (launcher ~:1800-1820) на critique→needs-plan делает голый `gh issue close` без --reason (дефолт gh = completed); re-plan prompt (crewboss-prep-spawn-gh.sh ~:264-269) всегда велит `gh issue create` — режима «edit existing» нет. Сами ревью были содержательно правильными; GC — намеренный (анти-stale), дефект — в COMPLETED-reason и полном regeneration.
- Коррекция классификации: v3-листья ревьюятся как materialized issues by design (#382) — фикс обязан сохранить reviewability; даже принятое поколение минтилось спекулятивно (v3 создан 22:47:29Z, agreed 22:55:27Z).

**F2. span_max-гейт: opaque rejection, трижды за день (P2/P3, CONFIRMED на #1274, #1290, #1291).**
- Все не-нулевые выходы composition-parse.sh схлопнуты в одно «approval-gate: composition block missing or invalid — routed back to needs-analysis (format round N/15)»: launcher:2353 отбрасывает exit code и stderr (`2>/dev/null … || _comp_tsv=""`), :2396 постит генерик; parser и сам не печатает нарушенный инвариант.
- Реальная причина всюду — Ф1: N leaves > span_max=5, exit 4. Аналитики диагностировали сами reverse-engineering'ом парсера (#1290 round-3: «Prior blocks were rejected by composition-parse.sh Ф1 invariant: 6 leaf lines > span_max=5 (exit 4)»).
- Оператор (#1274 @09:36:09Z): «фидбэк «invalid» без имени нарушенного инварианта не даёт аналитику сойтись — 15 раундов вслепую».
- Структурная ловушка: review-рубрика требует infra-engineer + qa + security лифы («a note in the composition body does not satisfy the rubric», @08:39:36Z) → 5-workstream чартер даёт 6 листьев — **jointly unsatisfiable** со span_max=5 без дропа скоупа. Стоимость на #1274: создан 01:39:49Z, план agreed 10:55:18Z (~9.2ч, ≥10 сессий аналитика).

**F3. Закрытые лифы навсегда несут in-flight лейблы (P3, CONFIRMED; root cause скорректирован).**
- Все закрытые интегратором лифы ночи (#1329–#1332, #1284, #1301, #1306, #1275/#1276, #1302–#1305…) — CLOSED со status:review + claimed-by:cb1; #603 — CLOSED со status:blocked; чартер #1073 несёт status:plan-review И status:approved одновременно. Close-коммент — только «Closed by integrator after merge <sha>», ни одной label-мутации (боксовый integrator: grep remove-label = 0).
- Коррекция: strip status:review **уже был** на main до прогона (9508aa6, 07-01, «prevent phantom chips») — ночная резидуа = deploy-lag (боксовый integrator Jun 30 без фикса). Реально unfixed везде: claimed-by:* не снимается никогда (нет пути ни в одном runtime-файле), терминальный status:approved на close не ставится («done means board» нарушен для лифов), charter-стек #1073 — от `|| true` на label-edit (:~1915).
- Риск латентный: все текущие selection-пути фильтруют state==OPEN; ловушка ждёт первый label-only запрос.

**F4. Орфанные открытые PR неделями (P3, CONFIRMED).**
- 3 из 4 открытых PR репо — орфаны: #369 (06-20, комментарий «superseded by rework» ЕСТЬ, close молча провален — F7-sweep #115: `gh pr close … 2>/dev/null || true`), пара #606+#607 (06-23) для закрытого-blocked #603 (leaf-PR и rework-PR оба висят, #607 MERGEABLE).
- Два продюсера: (а) merge-time sweep глотает фейлы close; (б) лифы, ушедшие в closed/blocked БЕЗ зелёного rework-мержа, не триггерят ни один sweep. #1290 P3 (`_cb_pr_supersede` на создании) — forward-only; реконсиляции «open PR при закрытом лифе / умершей ветке» нет нигде. Каждый тик они загрязняют integrator open-PR сканы.

**F5. P4-deliverable потерян на capability-mismatch роли (P2, CONFIRMED).**
- План #1274 назначил executor'у deliverable «открыть sub-issue #1274 с status:blocked-on-user type:infra» (token separation — фикс общего пула), но executor capability-gated от `gh issue create` (crewboss-gate.sh Layer A, tech-lead only). Ошибки не было — рецепт молча деградировал в body PR #1309; security-ревью F7 зафиксировал: «No such issue exists».
- Аггравация верификатора: лейбла `status:blocked-on-user` вообще **не существует** в таксономии (есть только status:blocked) — план не валидировал ни verb, ни label; даже tech-lead исполнил бы план не буквально.
- Итог: операторский work-item невидим для queue-signal (state:open AND status:approved); sub-issue не открыт по сей день. Plan-gate не сверяет deliverable-verbs с capability-матрицей ролей (enforcement есть для fs/spawn, нет для board-write verbs).

**Статус:** в основном unfixed; status:review-strip — fixed on main via 9508aa6 (pre-run) — NOT deployed; doctor label-lint — on charter/1291, unmerged; supersede-on-create — fixed on main (a1e4f79) — NOT deployed.
**Чартер:** (1) отложить минтинг лифов до plan:agreed (план живёт на чартере; тест: 2-round critique = ровно один leaf set) ИЛИ reuse/edit существующих; GC закрывает с `--reason "not planned"` + «superseded by #N» на самом лифе; (2) composition-parse печатает нарушенный инвариант в stderr, лончер ловит exit 1/4 и постит конкретику («6 leaves > span_max=5»); согласовать role-floors рубрики со span_max (review/security-лифы вне span или auto-raise при security-триггерах); (3) close-leaf атомарно снимает claimed-by:*/status:* и ставит терминальный статус (одна субкоманда, не два gh-вызова); one-off sweep истории + board-invariant test «no closed issue carries in-flight labels»; (4) GC-pass орфанных PR (лиф закрыт / base-ветка умерла → comment+close), unmute F7 close-фейлов; one-off #369/#606/#607; (5) plan-gate сверяет deliverable-verbs и существование лейблов с capability-матрицей, reject на plan-time; немедленно — tech-lead открывает P4 sub-issue из body PR #1309.

### G. Роли и окружение исполнителей

**G1. Роутинг в отсутствующую роль = молчаливая смерть; каталог ролей вне деплоя (P1→P2, CONFIRMED; механизм уточнён).**
- #1281 отроучен в роль `triage`, файла которой на боксе не было — смерть за 39с без лога/коммента/смены статуса. Роли triage/reviewer/recovery-lead появились на боксе только руками оператора (mtime Jul 2 06:39 против 01:33 у остальных) — **вся** recovery/review-поверхность была недеплоена, blast radius шире #1281.
- Коррекция верификатора: fail-fast «role not found in manifest» в prep-spawn **существовал** (:314-316, pre-инцидент) — но лончер глушит весь вывод спавна (`( "$TRIAGE_SPAWN" … >/dev/null 2>&1 ) &`, box:513/main:912), так что ошибка не дошла ни до лога, ни до борда; grep «not found in manifest» по launcher.out = 0.
- Фикс `_cb_role_guard` (33dee46, +114 строк, 18 сайтов, «LOUD log and an issue comment naming the missing role … item stays retryable») + catalog-sync (e3b58dc) — только на unmerged charter/1291; на main и боксе grep = 0.

**G2. Triage: 0 вердиктов за всю историю петли (P2, CONFIRMED).**
- Полный grep лога: 6× «no verdict comment found» routing'ов (в т.ч. #897 — 86с, #1043), **0** реальных вердиктов, 0 «crash-death» retry-строк после мержа фикса — смерженный #1304 (CB_TRIAGE_MIN_LIFETIME=60 + RETRY_CAP=3 + backoff) ни разу не исполнялся вживую.
- Механизм ночи: completion handler читал «нет вердикт-коммента» как осознанный no-verdict → triage_done=1 + term=1 → одна попытка на жизнь лифа; спавн triage — в тот же шторм, от которого спасает (общий gh failure-domain).

**G3. seccomp SIGSYS на `gh pr create` — системный, с побочным демонтажом фиксов (P2, CONFIRMED).**
- Минимум **7 лифов** ночи независимо переоткрыли workaround: #1281 («PR created successfully via the REST API (the gh pr create subcommand kept hitting a sandbox SIGSYS crash, so I used gh api which works)»), #1300 (также `gh issue comment`), #1303, #1329, #1330 (также git upload-pack), #1331, #1332 («gh pr create's git-detection path trips the sandbox seccomp filter»).
- Аггравация: промпты мандатируют `cb_pr_create`, который SIGSYS'ится → каждый агент обходит raw `gh api`, **молча теряя RL-floor и _cb_pr_supersede** (#996/#1043) — workaround разбирает более ранний reliability-фикс.
- Не чинится нигде: claude.kafel не тронут; cb-pr-create.sh:125/127 — raw exec без REST-fallback; charter/1291 эти файлы не трогает. Единственное смежное — smoke-runner избегает `timeout`-обёртки curl (та же политика убивает timeout).

**G4. Visual gate: rc=127 = «docker: command not found», сентинел без срока (P2, CONFIRMED; причина уточнена).**
- Ни docker, ни podman на боксе нет (`command -v` оба rc=1), integrator зовёт `docker run` (box:505/main:524); provision-podman.sh лежит в репо неисполненным; image-digest валиден (playwright v1.60.0-jammy).
- `run/visual_gate_soft` (0 байт, Jun 27 16:54) «temporarily» глушит гейт 6+ дней; на main обход полностью молчаливый (`visual_rc=0`, ни строчки лога), expiry/alert нет; doctor visual-проверок не имеет. UI-чартеры едут без visual regression; rc=127 использован как обоснование ручного merge-around #1281.

**G5. Хронически красный baseline + env-протечка (P2, CONFIRMED).**
- На чистой базе красные: ui-api-contract (extractor `grep -oP 'a=="…"'` слеп к constant-based dispatch `a == CMD_APPROVE_HD` — проверено в коде), plan-convergence CAP6 (харнесс наследует CB_PLAN_CONVERGE_CAP=8; run_loop не hermetic — sibling-тесты уже используют env -i/env -u), per-charter-auto-gate S3/S4.
- Итог: executor и оператор stash-верифицируют вручную («I confirmed each fails identically with my changes stashed»), merge #1289 зафиксирован как «operator: gate env-broken, code stash-verified» — нормализация оверрайда гейта. Не тронуто ни одной ночной веткой.

**G6. verify-merged smoke жёстко зависит от живого gh — ложные confirmed-RED (P1, CONFIRMED; fixed main, not deployed).**
- smoke ассертит непустой борд из /api/state (`assert b is not None and len(b) > 0, "board-empty"`); борд строится живыми gh-вызовами → в RL-окно 403 = «confirmed code RED».
- 3 confirmed FAIL по #1281 (04:56:09/05:08:47/05:18:51Z — PR #1286/#1288/#1289), каждый предварён «retryable red … flake n/5» за ~60-70с — flake-retry ре-тестил внутри того же шторма (шторм 3+ часа vs окно 60с), «retryable» всегда эскалировал в «confirmed»; rework-cap 2/2 сгорел на корректном коде; оператор: «verify-merged на этом боксе структурно не способен дать GREEN … (все 4 RED — в мёртвые RL-окна)».
- Фикс #1290 P1 (fb7a09c: infra() classification + post-hoc real-gh probe, `infra "gh-403-board" 3` retryable, never code-red; integrator не кэширует infra-вердикты) — на main; на боксе отсутствует (smoke-runner Jun 29, 0 хитов gh-403-board) → следующий шторм повторит класс до деплоя.

**G7. Пустая причина «(RED)» отключает эскалацию (P3, CONFIRMED).**
- Post-reset confirm'ы 07:05:27/07:14:12Z — голое «blocked (RED)» против информативного «(smoke:api-state-invalid:crewboss-api.py)» ранее: launcher:897 парсит `RED_REASON:` из vm_out (stderr отброшен), :903 фолбэк `${_vmreason:-RED}`.
- Хуже косметики: :909 сохраняет пустой red_reason, а :640 `_recovery_escalate` явно бейлится на пустой причине («manager blind, #1110») → пустой reason тихо деградирует recovery-эскалацию в plain blocked. Не ново (то же у #1043 06-29/30); доминантный триггер закрыт fb7a09c (mandatory `RED_REASON: infra:<sig>`), сам фолбэк-паттерн жив на main.

**G8. Операторский сброс парковки неэффективен (P3, CONFIRMED; root cause скорректирован).**
- Флип лейбла в review (06:40Z, «вернул в review для пересуда verify-merged на живых пулах») не чистил run-state: rework_n=2/flake_n=3 персистентны → оба post-reset confirm'а сказали «rework-cap (2/2) reached → blocked».
- Коррекция: `cmd_redispatch` (#210) существовал и на боксе — но чистит rework_n и НЕ чистит flake_n/triage_done, и уничтожает work tree; лёгкой операции «re-adjudicate verify-merged на существующем PR со сбросом капов» нет; плюс discoverability-гэп. И каузальность уже: GREEN смержился бы несмотря на cap — re-block случился потому, что verify-merged снова упал (RL-шторм жив в 07:00:57Z).

**G9. crewboss-api.py глотает gh-ошибки (P2, CONFIRMED).**
- Хелпер `sh()` (:40-42): gh 403 выходит ненулевым БЕЗ исключения — returncode/stderr отбрасываются на нормальном пути (возвращается только .stdout), except покрывает лишь timeout/OSError; борд отдаётся пустым с HTTP 200 и нулём следов — именно это не давало smoke отличить «gh dead» от «board broken».
- #1290 сознательно обошёл в smoke (post-hoc gh probe), API «deliberately NOT in scope» — silent degradation жив; degraded-флага/gh_errors в /api/state нет; файл sha-locked в манифесте (regen в том же PR).

**Статус:** env-fail classify + triage-retry + rework-hygiene — fixed on main via PR #1318 — **NOT deployed**; role guard + catalog-sync — on charter/1291, unmerged (band-aid: ручной scp ролей 06:39Z); seccomp / visual gate / baseline reds / api sh() / reset-op — unfixed везде.
**Чартер:** (1) seccomp: воспроизвести SIGSYS в jail-test, поймать syscall (audit/strace), расширить allowlist ИЛИ стандартизовать REST-путь в cb-pr-create для всех ролей (вернув RL-floor/supersede); jail-smoke с draft-PR; (2) visual gate: provision podman + перевести интегратор, pre-pull digest, sentinel expiry + громкий per-tick лог + doctor-check rc∈{0,1}; (3) baseline: env-scrub (env -u) в run_loop plan-convergence, extractor под constant dispatch, nightly clean-base прогон с авто-issue на любой baseline-red; (4) api.py: surfacing обоих путей (non-zero exit И exception) + degraded:true/gh_errors в /api/state; (5) расширить re-dispatch (flake_n/triage_done) + review-preserving re-adjudicate + документация counter→cap; (6) live-валидация triage-вердикта (sacrificial code-RED) + алерт «роль с 0 вердиктов за N спавнов»; (7) mandatory RED_REASON (пустой → «infra:no-reason-captured», retryable) + regression-тест пропагации; (8) разглушить спавн-вывод; канарейка на absent-роль после деплоя 1291.

### H. Keepalive / watchdog / оверсайт-мосты

**H1. Keepalive самоотключён с 19:16:50Z — механизм доказан fuser'ом (P2, CONFIRMED).**
- Direct-launch (nohup fallback) не закрывает lock fd; запущенный лончер (pid 325828) унаследовал flock → каждый 5-мин тик с 19:16:50Z — «another keepalive tick holds the lock — skip». Последняя не-skip строка — сам запуск 325828.
- **520** skip-строк с первой (07-01 07:00:28Z); 11ч+ подряд после финального запуска; journalctl: сервис стартует и деактивируется в ту же секунду (ноль работы). Умри стоящая петля этой ночью — рестарта не было бы (frozen-night вектор).
- fuser на keepalive.lock: держатели — pid 325828 (сам лончер) + сабшеллы + sleep. Partial fix faae6f6 (#1268, systemd-unit путь, charter #1144) — on main pre-run; unit на боксе не установлен, боксовый скрипт без LAUNCHER_UNIT-кода, nohup-fallback fd-leak не починен и на main (:120).

**H2. Relaunch-шторм недосчитан в 5 раз (P2, CONFIRMED критиком).**
- keepalive.out фиксирует **10** «loop DOWN -> direct launch» за 2ч06м: 17:10:19, 17:50:28, 17:55:28, 18:00:15, 18:05:03, 18:10:28, 19:00:00, 19:05:12, 19:10:09, 19:16:50Z (срезы видели два).
- Лончер false-idle-выходил почти каждый keepalive-интервал двух полос шторма; каждый релонч — свежий pid, ре-чтение борда на мёртвом пуле, сброс in-memory state (кэши, backoff-счётчики). 10 поколений лончера; возможный overlap/double-processing тиков не аудирован. Плюс голый «Terminated» 19:16:37-50Z, mtime launcher.lock = 19:16.
- Стретчи «loop DOWN на почти каждом тике» тянутся 12:50–19:16Z — #1144 cgroup-teardown симптом, пока запуск 19:16:50Z не выжил и не захватил lock.

**H3. Auto-unblock-мост мёртв с 06-30, люди делали его работу руками (P2, критик).**
- ~/cbnet/auto-unblock-approval.sh («temporary bridge until #955 fixes the manifest-approval stall»: plan:agreed + composition:approved + !status:approved → add status:approved) авто-аппрувил 6 чартеров Jun 29-30, последняя запись auto-unblock.out — 06-30 14:35:31Z, дальше ноль за всю ночь.
- **Никакого шедулера вообще:** нет unit/timer (только crewboss-api + keepalive), crontab пуст, процесса нет. При этом оператор хот-патчил скрипт при rename 07-02 08:32 (.bak-rename существует) — считал живым.
- Ночью его целевое условие дважды закрыто вручную: #1274 18:43Z, #1290 19:34Z — ~45 мин человеческой латентности против одного 5-мин тика моста. Класс: операторские safety-nets — unmanaged-процессы без liveness-контракта; doctor о них не знает. Тот же silent-death класс, что и frozen night, слоем ниже.

**H4. Frozen-night watchdog #1142 (P1, справочно + гэп).**
- Исполнение чартера чистое: 2 review-раунда поймали спековые баги до кода (никем не выписываемый run/start-ts → cold-start false alert на каждом деплое; несуществующий ops:alert label; неверный .order[] предикат; мнимый ntfy endpoint); лифы single-pass, PR #1279 → main 03:32Z.
- Но: (а) на боксе `_stall_check` = 0 — не взводился ни разу (тема A3); (б) его предикат исключает blocked-лифы → blocked-head стойло темы D для него «idle» (тема D4). Логика на main верифицирована (:1534, per-tick вызов :2177, cold-start fallback, dedup ops:alert).

**Статус:** partial — systemd-путь keepalive fixed on main (faae6f6, pre-run) — NOT deployed; nohup fd-leak, relaunch-cap, мост — unfixed.
**Чартер:** (1) установить crewboss-launcher.service на бокс + деплой faae6f6-пути; в nohup-fallback закрывать/CLOEXEC lock fd перед exec; skip-сообщение различает «lock held by launcher pid N (fd leak!)» от «concurrent keepalive»; при lock >2 тиков — лог держателя (fuser) + read-only liveness probe; doctor: последняя не-skip запись keepalive.out < 24ч; (2) relaunch-rate cap с эскалацией (N запусков за M минут → alert-артефакт вместо тихого чёрна); аудит overlap'а 10 поколений 17:10–19:16Z; (3) инвентаризация aux-демонов (auto-unblock-approval.sh, bridge.py, wait-loops) → systemd timer или launcher-цикл; doctor freshness-check по манифесту «живых» *.out; ретайр моста, если реальный фикс #955 доедет (он merged, но — merge≠deploy); (4) верификация watchdog live после деплоя: симулировать стойло → ровно один ops:alert.

### I. Закрыто ночью (справка)

- **approve-gate-three-site-inconsistency (#1220, P1)** — fixed on main via PR #1294 @07:34:57Z (merge 39b21c75): build_state/approve-guard/CLI выровнены по policy-nested plan_review_role; 690-тест переведён на real source (CB_690_MODE=source). CLI-«спасение» работало только потому, что было unguarded — фикс одновременно разблокировал кокпит и закрыл байпас. Residual: аудит других guard-предикатов, продублированных launcher/api/CLI. NOT deployed (боксовый api.py в MISMATCH-списке).
- **triage-crash-death-terminal-parking (#1290 P2, P2)** — fixed on main (0887651: crash-death дискриминатор + retry-cap + backoff). Инцидент — утро 07-02 (до окна), парковка повторилась 3 раза при живом операторе. NOT deployed; фикс ни разу не исполнялся вживую (см. G2).
- **rework-pr-proliferation (#1290 P3, P2)** — fixed on main (a1e4f79: `_cb_pr_supersede` при создании PR; старый sweep #115 был только cleanup-on-merge — в шторм без мержей и копилось). Residual: raw `gh pr create` остался в launcher:1471. NOT deployed.
- **night-charters-landed (P3)** — 4 из 5 чартеров закрыты status:approved и на main (#1142 PR #1279 03:32Z, #1220 PR #1294 07:35Z, #1274 PR #1312 20:47Z, #1290 PR #1318 21:59Z; в само окно попали только два последних). Предложенный файндером follow-up «smoke → ENV-FAIL вместо RED» **уже реализован** #1290/#1303 — не дублировать. Всё — merged, NOT deployed (тема A).

### J. Отвергнуто верификацией (REFUTED)

- **manual-plan-approvals-bypass** — REFUTED. Оба «ручных» plan-гейта на деле доставлены петлёй, чтящей агентские plan:agreed: бот ruslan-cb-bot поставил лейблы (10:48:20Z / 18:49:13Z), промоушены в status:approved исполнил сам лончер (посекундное совпадение лога и label-edit; #1274 — до рестарта 19:17Z). Реальная аномалия — false-fail plan-review под RL (D5/E6) + невозможность различить human/loop-действия лончера на общем токене; ручным был только clear term-флага в run-state. Provenance-чартер может иметь ценность, но его мотивирующий инцидент в исходной формулировке ложен.
- **stale-owner-urls-in-live-state** — REFUTED. Все эмиссии stratch1989-URL датированы ДО rename-хотпатча (последняя — 08:10:39Z 07-02; первая ruslan-shaydullin-строка — сразу после); run/state — 0 ссылок, живые скрипты чисты (CB_REPO=ruslan-shaydullin), body #306 — 0 вхождений. Остатки — только в намеренных .bak-rename бэкапах и мёртвых архивных workdir'ах (run/work/16,17). Salvage: grep-гейта на старого владельца в doctor/CI нет (дешёвое hardening — ник claimable); архивные клоны держат https-remotes на старого владельца — риск только при ре-исполнении внутри мёртвых директорий.

---

## Черновая нарезка чартеров

| # | Prio | Рабочее название | Что входит (темы) | Зависимости |
|---|---|---|---|---|
| 1 | P0 | **unblock-1291-and-land** | Однострочный qa-фикс finale-hygiene.test.sh:349 на charter/1291 → unblock #1333 → merge → деплой finale/role-гардов; решение по #306; миграция status:hold во всех циклах (C, D-immediate) | операторская рука (in-loop чинить некому) |
| 2 | P0 | **deploy-is-an-act** | Полный деплой ночных мержей на бокс; box-observable acceptance rollout-лифов + integrator refuses close без deploy-report; doctor behind-main probe → ops:alert; фикс deploy-live-swap (detached/keepalive, tick-probe, preflight); manifest completeness (smoke-runner + все runtime/*); .bak/zombie GC + boot-sha баннер (A) | вместе/после №1 (иначе деплой неполного набора) |
| 3 | P1 | **final-review-lifecycle + queue-defer** | Runtime-контракт non-PR лифов (verdict consumption, review-stale exemption, шаблон triage-parser); qa-rework путь в tests/ + forced-on прогон SKIP-групп; queue park на blocked head + расширение _stall_check + idle-backoff; three-state gh-reads + громкие board-route фейлы + term-reconcile watchdog; фикс jq role getter board-gh.sh (D) | — |
| 4 | P1 | **enforce-approval-gates** | oversight:human лейбл + integrator hard-skip; plan-stage FAIL на prose-only гейты; blocking security findings → RED-тест/лейбл; реализация F4/F5/F6 + empty-PATH; аудит прошлых байпасов (B) | вопрос convergence-override (#1220 P2 blocked) |
| 5 | P1 | **rl-hardening-v3** | Idle-exit только на успешном чтении борда; довайрить GQL-диету (behavioural acceptance = live-вызовы/тик); infra-классификация всех capped-путей + three-state probes; format-гейт (fetch≠parse, counter по композициям); api.py cache/TTL + shim; 5xx=retryable infra; P4 token-separation sub-issue (E, F5) | деплой RL v2 (№2) |
| 6 | P2 | **executor-environment** | seccomp allowlist / REST-стандартизация cb-pr-create; visual gate runtime (podman) + sentinel expiry + doctor check; baseline reds (env-scrub, extractor, nightly clean-base); api sh() surfacing + degraded-флаг; re-adjudicate/reset op; live-валидация triage + zero-verdict алерт; RED_REASON mandatory; разглушить спавн-вывод (G) | — |
| 7 | P2 | **plan-and-board-hygiene** | Отложенный минтинг лифов / not_planned+supersede; span_max-гейт с именем инварианта; rubric-vs-span_max; close-leaf label strips + терминальный статус + sweep + invariant-test; orphaned-PR GC + unmute F7; plan-time verb/label capability check (F) | — |
| 8 | P2 | **supervision-nets** | launcher systemd unit на бокс + keepalive fd CLOEXEC + отличимый skip-диагноз; relaunch-rate cap + overlap-аудит 10 поколений; инвентаризация aux-демонов + doctor freshness; ретайр/переустановка auto-unblock моста; live-верификация _stall_check (H) | частично №2 (деплой faae6f6) |

Сквозной принцип для всех восьми (уроки ночи): acceptance инфра-лифов — только по наблюдаемому эффекту на живой системе; «зелёные стаб-тесты ≠ рабочая фича»; merged ≠ deployed ≠ validated-live.

---

## Постскриптум: полный деплой выполнен 2026-07-03 ~06:44–06:56Z (после сбора фактуры)

Операторская половина чартера №2 исполнена вручную сразу после сбора: quiesce через `run/kill_switch` (петля вышла чисто на границе тика 06:45:19Z; keepalive.timer остановлен первым), затем полный `deploy-runtime.sh` (78 canonical-файлов + manifest copy + UI rebuild + рестарт crewboss-api), `smoke-runner.sh` доставлен вручную (A6 — вне манифеста), exec-биты новых файлов поправлены руками (`deploy-runtime.sh` не делает chmod — ещё один A-гэп), `deploy-units.sh` установил 4 systemd-юнита. Петля теперь работает под собственным `crewboss-launcher.service` (PPID 1, свой cgroup — путь #1144/faae6f6 активирован); **лог тиков ушёл в `journalctl -u crewboss-launcher`, а не в `run/launcher.out`**.

Верификация: первый тик на новом коде 06:52:06Z (маркер `loo-set=[…]` — фича #506, которой на боксе не было); симлинк `gh -> gh-shim.sh` создан вайрингом #1301; **FIELD-TEST PASS** — pid 2254722 пережил ручной keepalive-тик, keepalive впервые за сутки реально оценил liveness («loop alive — nothing to do») вместо skip по унаследованному локу (H1 разорван). Post-deploy doctor: 27 MISMATCH исчезли, остались ~77 EXTRA (мусор из A7).

Что это меняет в нарезке: зависимость №5 от деплоя RL v2 — снята; unit-часть №8 — закрыта (fd-CLOEXEC nohup-fallback, relaunch-cap, мост — остаются); №2 сводится к системной части (box-observable acceptance, doctor behind-main probe, фикс deploy-live-swap, manifest completeness, GC). №1 (unblock-1291) остаётся первым действием: charter/1291 по-прежнему unmerged, и задеплоенный main-код всё ещё несёт finale-storm класс (C) и отсутствие role guard (G1).

---

## Не проверено / хвосты

Из critic gap-closure (negative results — не передиспатчивать эти проверки):
- **Per-role model channel** — чисто: все 17 ролей на боксе с `model:` frontmatter, оба spawn-пути через `--agent $ROLE` (crewboss-spawn.sh:91, prep-spawn:245,444); 0 «unknown/invalid model» строк в окне.
- **type:human-decision за ночь** — только #1296 (composition #1274, closed 09:38:21Z), уже покрыт срезом.
- **Operator-git-аннотации с 07-01** — только 77401f8 (ручной мерж #1289), покрыт.
- **Jail/podman/SIGSYS sweep по окну лога** — ничего нового; единственный сырой script-error («ble.: command not found» + «id: unbound variable» ×2) — единичный, 2026-06-22, pre-run; грепнуть при следующем касании launcher-gh.sh.

Непроверенные хвосты (кандидаты на follow-up срез):
- Операторские comment-таймлайны на out-of-charter issues #306/#291/#603 (экономили общий токен).
- crewboss-api.service journal / run/api.out — точная доля дашборда в GraphQL-бёрне (attribution launcher vs api vs jails — только rate_limit-снапшоты; доминирование API выведено из CPU/child-процессов, не измерено прямо).
- Per-leaf run-state журналы трёх ~39с triage-смертей — фактический stderr/stack ни в одном срезе не captured.
- Возможный concurrent-overlap 10 лончер-поколений 17:10–19:16Z (double-processing тиков; нужен pid-tagged разбор 212k-строчного launcher.out).
- Назначение и живость ~/cbnet/bridge.py (Jun 30 18:16, не инспектирован).
- GitHub-side CI/Actions прогоны за ночь.
- Из verdict-notes: прогноз «#1291 — следующий finale-storm кандидат при закрытии #1333 без фикса» — hazard, не наблюдённое событие; root-cause phantom-deploy («capability jail без box-seam») — plausible, из логов не доказана (доказан только repo-locally satisfiable acceptance); присутствие #1290 P3-фикса на боксе одним верификатором не перепроверялось (read-only) и опровергнуто соседним (mtimes/sha) — считать недоставленным.

---

*Воспроизведение сбора: forensics-workflow из 78 агентов — 6 параллельных срезов (charter-1291-finale-hygiene, charter-1220-oversight, charter-1274-ratelimit, charter-1290-1142-loopfixes, box-forensics, board-current-state) + critic gap-closure, затем адверсариальный verify-пасс по каждой находке (re-check эвиденса у источника: gh API, read-only ssh на бокс 3.217.199.168, git main/charter-ветки; вердикты CONFIRMED/REFUTED с коррекциями severity и root cause). Дата сбора и верификации: 2026-07-03.*
