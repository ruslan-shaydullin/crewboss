# crewboss — общий план (consolidated)

> Сводка по всем трекам. Детали — в профильных доках (ссылки внизу). Ветка `crewboss`.
> Легенда: ✅ сделано · 🟡 частично · ☐ не начато · 💲 нужен включённый EC2 + траты пула · 🙅 блок на инфре/человеке.

## A. Движок (jail + launcher + governance) — ✅ доказан end-to-end (3a→R11)
- ✅ Джейл: ФС-изоляция (3a) + сеть с egress-allowlist через прокси (3b) + seccomp «третий гвоздь» (3c).
- ✅ Спавн-примитив + рельсы: redact_secrets, budget-гард, status.json/run.log, per-task прокси.
- ✅ Launcher-loop: предикат launchable, claim, routing, retry→blocked, reconcile, single-instance, kill/pause-флаги, бэкграунд-параллель.
- ✅ Реальный GitHub-board-адаптер (issues+labels ⇄ стейт-машина).
- ✅ Governance в джейле: `--agent executor` + PreToolUse-гейт (merge live-заблокирован), tool-absence.
- ✅ Полный цикл boss→tech-lead→executor через лаунчер (живой PR, dependency-ordering).
- ✅ Provision/doctor: самодостаточный установщик (идемпотентный путь зелёный).

## B. UI (web-дашборд) — ✅ фундамент + борд + команда
- ✅ Ф0: demon-API (HTTP+SSE+auth), React/Vite-приложение.
- ✅ Board: hero-метрики, иерархия charter→tasks, рейка живых агентов, task-detail drawer (бриф+лог+фаза), confirm-предсказуемость, тосты.
- ✅ Team (org-chart): дерево ролей, collapse/zoom, **drag-drop редактирование + пул ролей**, live-валидация инвариантов, Export/Save.

## C. Концепция (org-model + манифест) — ✅ спека, 🟡 исполнение
- ✅ Концепт: гибрид (отделы-пул + сборка-через-анализ), управляющие/аналитики/исполнители, span≤5, топы без кода, under-staffing-защита.
- ✅ Формат манифеста (spec v0) + пример + валидатор `manifest-doctor`.
- ☐ **Лаунчер ИСПОЛНЯЕТ манифест** — сердце концепции (ниже, приоритет №1).

---

## Что осталось — приоритизировано

### P1 — Сердце концепции: лаунчер исполняет манифест 💲
Сейчас лаунчер гоняет захардкоженный boss→tech-lead→executor. Обобщить на манифест:
- ☐ на чартер запускать **обязательную аналитическую стадию** (`analysis_roles`) → предлагает подход + состав из библиотеки (рубрика как floor);
- ☐ **аппрув состава** (`approval_role`/человек по порогу) до запуска;
- ☐ собрать **под-команду** (N-уровней, span≤5) и прогнать листья;
- ☐ `profiles/<role>.cfg` — связать роль с её sandbox-профилем (маунты/seccomp/доступы);
- ☐ un-correlated критик состава + дешёвая эскалация на лету (blocked→пере-анализ).

### P2 — UI до «продукта» (без бокса/трат — можно параллельно)
- ☐ Ф3: создание задачи/чартера **формой**; live-стрим мыслей агента (нужен `stream-json` в спавне 💲); boss-чат-пейн.
- ☐ Ф5 анимации (переходы состояний, реордеринг); Ф6 геймификация (флот-персонажи, празднования, уровни).
- ☐ Ф7 a11y/локаль/адаптив; Ф8 тесты/перф/нотификации.
- ☐ Создание/редактирование роли из UI (форма → `roles/<role>.md`).

### P3 — Боевой Quarter + надёжность 💲🙅
- ☐ Provision **cold-тест** на свежем EC2 (проверить «do»-ветки).
- ☐ review→done merge: нужен branch-protection / 2-й ревьюер 🙅 (public/платный репо).
- ☐ Боевой Quarter: node→20 + Expo-гейт (пере-снять seccomp-политику), fine-grained PAT, чартер-ветки.

### P4 — OSS-релиз
- ☐ Публичный репо + LICENSE, англ. README/гайд, демо-видео.
- ☐ Static nsjail-бинарь (per-arch) + переносимость (Tier-1 Linux+userns; ARM64-регенерация политики).

## Доки
- Движок/прототип: [launcher-prototype-log.ru.md](launcher-prototype-log.ru.md) · [launcher-design.ru.md](launcher-design.ru.md) · [board-orchestration.md](board-orchestration.md) · [ec2-provision.ru.md](ec2-provision.ru.md)
- Концепция: [org-model.ru.md](org-model.ru.md) · [manifest-spec.ru.md](manifest-spec.ru.md) · [team-example/](team-example/)
- UI: [ui-roadmap.ru.md](ui-roadmap.ru.md) · [ui/README.md](ui/README.md)
