# Oversight / plan-approval — стратегия лечения (milestone #1219)

> Трекинг: milestone **#1219**. Фазы: **P1 #1220** (api-only bugfix) · P2/P3/P4 — заводятся по ходу.
>
> Записано как канон по согласованию с юзером (2026-07-01). Источник — многоагентный разбор
> живого `origin/main` (14 агентов). НЕ править точечно под ходом реализации; расхождения
> реальности с этим планом фиксировать отдельным spec-drift, как в `analysis-in-the-loop-*`.

## Север

Одна ось oversight на чартер, вычисляемая заново каждый тик на ребре `plan-review`, с ОДНИМ
precedence-правилом. Человека можно **добавить** поверх (форс-аппрув на сложный чартер), но
автоматика никогда не может **молча снять** сконфигурированный quality-гейт. Автономность —
это операторская политика (env / manifest-ключ), а не хардкод.

## Главная беда

Исходная одна клауза «charter approved» (Arch-2, launchable-предикат) разрослась в **ЧЕТЫРЕ
наслоённых plan-стадийных механизма**, а precedence между ними живёт только в одном guard'е
`[ -z "$_plrr" ]`, переписанном в ~4 местах лаунчера и в `crewboss-api.py`. Нигде не
задокументировано. Ровно тот sprawl, о котором предупреждал `board-orchestration.md:90-92`.

Четыре механизма plan-гейта:
1. **plan-convergence (#382)** — `plan_review_role` в манифесте → аналитик ревьюит план по
   раундам; `plan:agreed` → лаунчер промоутит `plan-review → approved`. Кап
   `CB_PLAN_CONVERGE_CAP` → `type:human-decision` (defer-and-continue).
2. **auto-label / env (#401)** — `CB_AUTO_PLAN_APPROVE=1` ИЛИ лейбл `auto:plan-approve` →
   само-промоут, но **только если `plan_review_role` НЕ задан** (guard `[ -z "$_plrr" ]`).
3. **composition-cost-гейт (#138)** — `approval_role` + `human_approval_above_usd`; HD-2
   `est=(spent_usd/runs)×leaf_count`. Это **предыдущая стадия** (`team-review`), не
   конкурент plan-гейта — композируется, не перебивает.
4. **acceptance-convergence (#522)** — `acceptance_review_role` + `auto:merge` — merge-гейт,
   ещё позже.

Плюс ортогональный сигнал риска `blast-radius:high|low` (#262, сериализация диспатча).

## Кнопка «мёртвая» по ТРЁМ разным причинам

1. **Мёртвая-по-симптому** — при глобальном `CB_AUTO_PLAN_APPROVE=1` чартер само-промоутится
   до того, как человек посмотрит (launcher `origin/main:~1611`). Кнопка есть, до неё не доходит.
2. **Мёртвая-по-дедлоку (отгруженный баг, самое острое)** — `crewboss-api.py` build_state
   считает `plan_convergence_active = ("plan:agreed" not in labels)` и approve-guard
   отклоняет approve — **оба забыли проверку `plan_review_role != ''`**. Поэтому role-empty
   human-park чартер помечается «convergence in progress» (кнопка спрятана) И approve
   отклоняется с пустым именем роли → **чартер нельзя аппрувнуть из кокпита**, спасает только
   **незагарженный** CLI `crewboss approve`. `690`-тест содержит ПРАВИЛЬНУЮ логику в своей
   reference-impl, но тестирует её отдельно от продакшена → **false-green**.
3. **Мёртвая-по-дизайну (корректно)** — при реальном convergence кнопка прячется до
   `plan:agreed`. Это штатное поведение #690, его оставляем.

## Настоящая нехватка (запрос юзера)

Единственный per-charter approval-лейбл — `auto:plan-approve` (opt-in в *больше* авто).
**Обратной ячейки нет**: нельзя пометить один сложный чартер «этот требует МОЕГО аппрува»,
пока авто включён. `hold` — полный STOP, не scoped-гейт. OPEN **#325** (лист под #304)
вводит `auto-approve:no` = «force human gate», но заскоуплен на **composition-cost-гейт
(#138)**, не на plan-review → твою ячейку он всё равно не закрывает. → координируемся с #325
по неймингу, не дублируем.

## Реальный режим live-борда (важно для приоритета)

Живое свидетельство: все недавние релизнутые чартеры (#1181, #1131, #1049, #994, #993, …)
несут `composition:approved + review:agreed + plan:agreed + status:approved`. То есть бокс
крутится в **manifest-режиме с двойной сходимостью** (composition-reviewer #334 + plan-reviewer
#382), а **НЕ на плоском `CB_AUTO_PLAN_APPROVE=1`**. Следствие: твои чартеры авто-релизятся
аналитиком через `plan:agreed` — это «мёртвая-по-дизайну» ветка, а не «по-симптому».

**→ Это переносит Открытый вопрос №1 из «уточнить» в ЦЕНТРАЛЬНЫЙ:** чтобы `oversight:human`
работал в ТВОЕЙ настройке, он должен **перебивать или стакаться с convergence**, а не жить
только в role-empty ветке. v1-вариант «уступать convergence с предупреждением» для этого
борда будет почти no-op. P1 от этого не зависит; P2 — зависит напрямую.

## Целевая модель

Ось `oversight` на чартер:
- **`oversight:human`** (НОВЫЙ лейбл) → человек-гейт. Паркуется в `plan-review`, лаунчер
  эмитит ОДИН идемпотентный `type:human-decision`, остаётся **terminal-for-queue** (доска
  едет — defer-and-continue, не заморозка). Кокпит показывает рабочую кнопку; релиз — обычный
  флип `status:approved` (НЕ через `plan:agreed` — он инертен для role-empty, launcher
  `:2237/:2321` обёрнуты в `[ -n "$_plan_review_role" ]`).
- **`oversight:auto`** (= существующий `auto:plan-approve` / `CB_AUTO_PLAN_APPROVE=1`) → авто.
- **ничего** → наследует дефолт (у юзера сейчас — convergence-релиз через `plan:agreed`).
- **`plan_review_role` задан** → agent-converge (#382).

## Precedence — одно правило (сверху вниз, first-match-wins, каждый тик)

```
0. hold                     → FROZEN (абсолютный veto)
1. require_decomp_leaves=0  → BOUNCE → needs-plan (структурный guardrail, до промоута)
2. oversight:human          → ЧЕЛОВЕК-ГЕЙТ  ← ЗАПРОС ЮЗЕРА (бьёт auto/env)
3. plan_review_role         → AGENT-CONVERGE (#382)
4. auto (label|env) & !R    → AUTO self-promote (auto НИКОГДА не перебивает R)
5. else                     → DEFAULT
```

Composition-гейт #138 — предыдущая стадия `team-review`, не строка таблицы. blast-radius —
ортогональная сериализация, но нужен **carve-out**: запаркованный `oversight:human` чартер НЕ
должен держать `_serializing_charter` lock, иначе `blast-radius:high` заморозит доску.

CLI/кокпит симметрия (один гвард на обе поверхности): approve ОТКЛОНЯЕТСЯ ⟺ `plan_review_role`
задан И `plan:agreed` отсутствует; РАЗРЕШЁН для role-empty. Закрывает открытую CLI-дыру и
чинит дедлок.

## Фазовый план

### P1 — фикс дедлока + мёртвой кнопки + CLI-дыры (api-only, отгружается независимо)
- **Scope:** `ui/server/crewboss-api.py` (build_state `plan_convergence_active` + approve-guard:
  добавить забытую проверку `plan_review_role != ''`; аддитивно отдать `plan_review_role` /
  round / cap в build_state для честного UI), `reference/bin/crewboss` cmd_approve (тот же
  гвард — закрыть CLI-дыру), `runtime-manifest.tsv` sha-regen для api.py.
- **НЕ трогает** лаунчер. **Ветка от `origin/main`** (локаль на 79 позади).
- **Acceptance:** role-empty plan-review чартер — кнопка ВИДНА и approve УСПЕШЕН (дедлок ушёл);
  convergence-чартер — кнопка спрятана, approve ОТКЛОНЁН И в кокпите И в CLI (дыра закрыта);
  `690`-тесты (guard + ui) остаются ЗЕЛЁНЫМИ (продакшен догоняет их reference-impl);
  `runtime-manifest.test.sh` зелёный после sha-regen.
- **Deploy:** api-only safe-рецепт (scp абс.путь → py_compile → бэкап → swap → restart
  crewboss-api), БЕЗ `deploy-runtime.sh`.
- **Ценность для ЭТОГО борда:** convergence-режим → дедлок в проде не всплывает (роль всегда
  задана), но **CLI-дыра реальна** (`crewboss approve` может обойти convergence) — P1 её
  закрывает и делает гвард консистентным. Дедлок-фикс — защита для role-empty режима.

### P2 — `oversight:human` per-charter + единый resolver-seam (blast-radius:high)
- **Scope:** лаунчер (guard авто-аппрува + новая human-park ветка с идемпотентным HD,
  terminal-for-queue + carve-out из `_serializing_charter`), `labels-setup.sh` (+ лейбл),
  `crewboss-api.py` (инъекция из create-payload + `awaiting_human_approval` в build_state),
  `ui/app` (чекбокс «Require my plan approval»), `bin/crewboss` (подкоманда `oversight`),
  sha-regen (api + launcher).
- **Зависит от P1 + от ответа на Открытый вопрос №1** (override / stack / defer под convergence).
- **Deploy:** полное окно (правка живой петли), под `keepalive.lock`, порядок api→ui.

### P3 — канонический precedence-док + чистка декларативной поверхности (blast-radius:low, docs)
- `board-orchestration.md` (единая лестница), `manifest.sh` (задокументировать 5
  недокументированных policy-ключей: `plan_review_role`, `acceptance_review_role`,
  `review_role`, `require_decomp_leaves`, `analysis_roles`), `cb-env-flags.md`.

### P4 — DEFERRED (не строим сейчас)
Risk-auto-эскалация (blast-radius / HD-2 / leaf-count авто-флагают дорогой план человеку) +
cost-gated plan-стадия (`plan_approval_above_usd`). Отложено: нужна бюджет-история; дублирует
#138; коллизия с OPEN #325; blast-radius-как-триггер заморозил бы доску. Ревизия — только если
«авто-аппрувнуло что-то дорогое».

## Что сознательно НЕ делаем

- ❌ **Не флипаем** `CB_AUTO_PLAN_APPROVE :-0 → :-1`: сломало бы `convergence.test.sh:326` и
  потребовало бы деплой-time свипа in-flight чартеров. Автономность — через env/manifest.
- ❌ **Не унифицируем** релиз на `plan:agreed`: он инертен для role-empty чартеров →
  унификация заменила бы рабочий флип вечным no-op-дедлоком. Два пути релиза — это правильно.

## Инварианты тестов (сохранить)

`690-tests-*` (имя поля `plan_convergence_active` и логика гварда — P1 приводит ПРОДАКШЕН в
соответствие с их reference-impl, не переименовывать поле), `per-charter-auto-gate.test.sh`
S1/S2, `convergence.test.sh:326`, `plan-convergence.test.sh` (converge/escalate/agreed-skip/
limbo), `plan-decomposition.test.sh`, `queue-plan-convergence.test.sh` (dual-head #422/#423),
`approval-gate.test.sh` N-1 (открытый HD не держит петлю живой — контракт для нового
`oversight:human` HD), `manifest-lib.test.sh` accessor, `runtime-manifest.test.sh` sha-lock,
verify-merged / red-CI (абсолютный veto, неприкосновенен).

## Миграция / back-compat

- Локальный чекаут ~79 коммитов ПОЗАДИ `origin/main`. Фикс #690, `plan_convergence_active` и
  `690`-тесты уже на origin/main. **Каждый чартер ветвить от `origin/main`.**
- `CB_AUTO_PLAN_APPROVE`: смысл сохранён, shell-фолбэк остаётся `:-0` (не флипаем). Теперь
  перекрывается per-charter лейблом `oversight:human`.
- `auto:plan-approve`, convergence (#382), composition (#138), acceptance (#522) — не тронуты.
- sha-lock: регенить `runtime-manifest.tsv` (api :36, launcher :38) в ТОМ ЖЕ PR.

## Открытые вопросы (решения юзера)

1. **(ЦЕНТРАЛЬНЫЙ — см. «Реальный режим»)** Под convergence-командой `oversight:human` должен
   **override** (аналитик пропускается, паркуемся сразу на тебя), **stack** (аналитик сходит
   план → потом ты подписываешь) или **defer** (convergence побеждает, лейбл игнор-с-
   предупреждением — v1)? Живой борд показывает convergence-режим → defer будет почти no-op.
2. Персистить автономность как manifest-ключ `oversight_default: autonomous` вдобавок к env?
3. Нейминг лейбла: `oversight:human` vs `auto-approve:no` (согласовать с #325) vs `plan:mine`;
   и точная формулировка чекбокса.
4. `oversight:human` + `blast-radius:high`: снять сериализацию, пока запаркован (рекомендация),
   или намеренная полная заморозка доски до аппрува?
5. Забытый запаркованный `oversight:human` чартер: авто-таймаут (N тиков → авто/blocked) или
   бессрочный парк с видимым HD (ок)?
6. Roadmap: явное лейблирование — единственная модель, или в перспективе risk-auto-эскалация
   (пересечение с OPEN #325 / #138)? P4 отложено; подтвердить, нужно ли вообще.
