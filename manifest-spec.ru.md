# crewboss — team manifest (формат) — spec v0

> Манифест = единый источник правды об организации (org-model.ru.md, Принцип №1): его
> **исполняет** лаунчер, **рисует** org-chart страница, **меняет** drag-drop редактор.
> Формат: JSON для дерева/рубрики (на боксе есть `jq`, у веба нативно, редактору писать легко)
> + `.md` для ролей (как нынешние agent-дефиниции). Пример: `team-example/`. Валидатор инвариантов:
> `team-example/manifest-doctor.sh` (на примере — VALID).

## Раскладка
```
team/
  org.json          # орг-дерево + policy (span, аналитики, аппрувер)
  rubric.json       # объективные триггеры сложности -> обязательные роли/аппрув
  roles/<role>.md   # библиотека ролей: capability (frontmatter) + system-prompt (body)
  profiles/<p>.cfg  # sandbox-профили (nsjail) ролей; по умолчанию = kind
```

## `roles/<role>.md` — роль (capability)
Frontmatter + промпт. Поля:
- `name` — id роли (== имя файла).
- `kind` — `executor` | `analyst` | `manager` (определяет инварианты ниже).
- `domain` — `backend/go`, `qa`, `analysis`, … (для маршрутизации/группировки).
- `tools` — список инструментов Claude (`Read, Edit, Write, Bash`).
- `profile` — ссылка на sandbox-профиль (по умолчанию = `kind`).
- `code_blind: true` — (для топов) роль не видит код (нет `Read`).
- `skills` — теги навыков (для подбора аналитиком).
- `model` — идентификатор модели Claude (`claude-fable-5`, `claude-opus-4-8`, …) или `anthropic`
  (дефолт-роутинг, флаг `--model` не передаётся). Определяет, с каким `--model` стартует агент.
  Правило прецедентности: role frontmatter `model` > `org.json policy.model_by_kind` (опционально)
  > дефолт бокса.

## `org.json` — структура + политика
- `policy.span_max` — макс прямых подчинённых (инвариант ≤5).
- `policy.analysis_roles[]` — роли обязательной аналитической стадии (kind=analyst).
- `policy.approval_role` — кто согласует состав/план (kind=manager); `human_approval_above_usd` — порог человека.
- `departments[]` — `{id, head}`; head обязан быть manager.
- `nodes[]` — `{role, reports_to}`; ровно один корень (`reports_to:null`); дерево.

## `rubric.json` — объективные триггеры (FLOOR для анализа, не «на глаз»)
`triggers[]`: `{id, when, require_roles[]?, require:"…"?, require_human_approval?}`. Аналитическая
стадия применяет это как минимум (факт), затем добавляет суждение. «Кажется простым» обхода НЕ даёт.

## Инварианты (проверяет `manifest-doctor.sh`)
- ровно один корень; все `reports_to` резолвятся; у каждого node-role есть `roles/<role>.md`;
- **span ≤ `span_max`** на каждого руководителя;
- **manager** — нет `Edit/Write/Agent` (не пишет код, не спавнит); **code_blind-топ** — нет `Read`;
- **analyst** — read-only (`Read,Bash`, нет `Edit/Write/Agent`);
- **executor** — есть `Edit`/`Write` (делает код);
- `approval_role` существует и manager; `analysis_roles` существуют и analyst; head отдела — manager.

## Как потребляют (один манифест → три потребителя)
- **Лаунчер**: читает `org.json` → на чартер запускает **аналитическую стадию** (`analysis_roles`)
  → та применяет `rubric.json` + библиотеку и предлагает состав → **аппрув** (`approval_role` или
  человек по порогу) → запускает под-команду листьев; маршрут «роль листа → кто берёт» из дерева.
- **Org-chart страница**: рисует `org.json` как иерархию + наложение живых агентов (из `/api/state`).
- **Drag-drop редактор**: пишет `org.json` обратно (репарент в пределах span); `manifest-doctor`
  валидирует перед сохранением (не дать сломать инварианты рукой).
- **doctor**: гоняет `manifest-doctor.sh` как часть `crewboss doctor`.

## Что осознанно НЕ здесь (по org-model)
- «Соло» нет; топ-менеджмент кода не касается; сборка всегда через анализ+аппрув — это
  инварианты, а не опции. Бюджет защищается cost-cap'ами, не пропуском стадий.
- Маршрутизация при сотнях ролей: домен-теги на issue как вход в анализ, не замена анализа.

## Открытое (след. шаги)
1. `profiles/<p>.cfg` — связать роль↔sandbox; пока default по kind.
2. Лаунчер: реально исполнять аналитическую стадию + аппрув-гейт (сейчас он гоняет tech-lead→executor).
3. Редактор drag-drop поверх `org.json` + валидация при сохранении.
