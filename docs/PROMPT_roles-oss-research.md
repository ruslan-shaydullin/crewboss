# PROMPT_roles — OSS-ландшафт (результат deep-research)

**Компаньон к [`PROMPT_roles.md`](./PROMPT_roles.md).** Это вывод многоагентного
ресёрча по поиску open-source проектов, близких к описанной там системе ролей и
гейтов (zero-trust к самому агенту: тех-лид-оркестратор + 3 слоя — действия /
готовность / диспозиция).

| | |
|---|---|
| **Дата прогона** | 2026-06-03 |
| **Метод** | deep-research harness: fan-out web-поиск → fetch источников → 3-голосовая адверсариальная верификация (нужно 2/3 «опровергнуть», чтобы убить утверждение) → синтез с цитатами |
| **Объём** | 102 агента, 20 источников, 100 утверждений извлечено, 25 верифицировано, **20 подтверждено / 5 убито** |
| **Run ID** | `wf_b098a02c-e36` |
| **Статус** | справочный артефакт; ничего в конфиге не применялось |

---

## Главный вывод

**Обе исходные гипотезы подтверждены фактами.**

- **Слой-1** (детерминированное гейтирование действий) — **закрыт хорошо**;
  натив Claude Code / Agent SDK делает ровно то, что описано в профиле.
- **Многоролевые planner-executor оркестраторы** — **распространены**, но ни один
  не держит роль **детерминированной launch-time identity**: все либо always-on,
  либо глобальный флаг.
- **Слой-2** (completion-gate на детерминированном пруфе **без** LLM-судьи) —
  **самый редкий**; найдено два частичных примера.
- **Точная связка** «тех-лид ведёт issues+milestones+sub-issues» × «роль через
  детерминированную identity, не always-on» × «completion-gate на пруфе без
  LLM-судьи» **не реализована ни в одном проекте целиком.** Куски существуют по
  отдельности и форкаются — **интеграция и есть оригинальный вклад профиля.**

---

## Сводная таблица

| Проект | Anthropic? | Роли (совпадение с профилем) | Тех-лид-функции (issues/milestones/sub-issues) | Слой | Механизм | Зрелость (на 2026-06-03) |
|---|---|---|---|---|---|---|
| **github/gh-aw** | да (+Copilot/Codex/Gemini) | нет | **ДА** — create/update/close issue, labels, **assign-milestone**, **link-sub-issue**, каждый capped | 1 | **детерм.** (read-only токен + safe-outputs исполняет отдельный write-job) | ~4.6k★, MIT, очень активен (v0.78.1) |
| **ComposioHQ/agent-orchestrator** | да | planner→executor (1 worker/issue) | нет (потребляет issues, не авторит) | **2** + делегирование | **детерм.** merge-gate = `green CI AND human-approved` (boolean) | primary, активен |
| **rjmurillo/ai-agents** | частично (Claude+Copilot) | **23–24 роли; decision/delegation vs execution + analyst-как-цель** | нет | (контрпример к 2) | **LLM-судья** (critic APPROVE/REJECT) | ~34★, MIT, 1193 коммита |
| **Claude Code agent-teams** (натив) | да | «team lead» спавнит teammates | нет (GitHub только как вход) | 1 + **2** | **детерм.** launch-флаг + `TaskCompleted`/`TeammateIdle` exit-2 | experimental, v2.1.32+, за флагом |
| **liberzon/claude-hooks** | да | нет | нет | 1 | **детерм.** (декомпозиция compound-bash, fnmatch, без LLM) | ~17★, MIT |
| **wshobson/agents** | да | домен-эксперты (не identity-гейт) | нет | — | — | 192 агента / 84 плагина |
| **Anthropic Agent SDK / permissions** | да | — | — | 1 | **детерм.** `hooks→deny→mode→allow→canUseTool` | primary docs |

---

## Карточки по ключевым находкам

### 1. Натив Claude Code / Agent SDK — Слой-1 уже в харнессе (подтв. 3-0)
Порядок оценки буквально `hooks → deny → mode → allow → canUseTool`. Bare-name
`deny` (напр. `Bash`) **убирает инструмент из контекста до оценки** — «Claude его
не видит и не может попытаться». Deny **не перебивается ничем, даже
`bypassPermissions`**. Для locked-down агента: `allowedTools` +
`permissionMode: "dontAsk"` → всё нелистенное отклоняется. Хуки дают
«детерминированный контроль, не полагаясь на выбор LLM».
**⚠️ Сплит 2-1:** «детерминированно» верно **только для shell-command хуков**; те
же доки описывают prompt/agent-хуки, дёргающие модель (напр. Haiku) — это НЕ
гвоздь. Различитель — не «есть хук», а **какой флавор хука**.
Источники: `platform.claude.com/docs/en/agent-sdk/permissions`,
`code.claude.com/docs/en/permissions`, `.../hooks-guide`, `.../hooks`.

### 2. github/gh-aw — ближайшее к тех-лиду как board-manager (3-0)
Safe-outputs каталог покрывает ровно борд-операции тех-лида как дискретные
capped-возможности: `create-issue` (max 1), `add-labels` (max 3),
`assign-milestone` (max 1, auto_create), **`link-sub-issue`** (нативные
parent/child), `close/update-issue`. Агент работает с **read-only токеном**,
записи делает **отдельный job с `issues: write`** — настоящий capability/identity
split, не LLM-судья.
**Gap (0-3, опровергнут оверклейм):** нет многоролевой структуры, нет слоя
делегирования субагентам, **нет completion-gate** (не проверяет, что работа реально
сделана перед close). Активация — per-workflow Actions-триггер, **не** launch-time
role identity долгоживущего оркестратора.
Источники: `github.com/github/gh-aw`, `github.github.io/gh-aw/reference/safe-outputs/`.

### 3. ComposioHQ/agent-orchestrator — единственный чистый детерминированный Слой-2 (3-0)
`ci-failed → send-to-agent (retries 2)`; `changes-requested → escalateAfter 30m`;
`approved-and-green → notify (auto-merge off by default)`. Условие мержа —
**boolean над объективным CI + human-approval**, LLM готовность не судит (агента
зовут только чинить). Самый чистый «green CI как истина, не самоотчёт» в выборке.
**Gap (1-2):** always-on после `ao start` («walk away»), **не** загейчен ролью; и
**не** авторит/триажит issues, не ведёт milestones, не декомпозирует — потребляет
готовые issues.
Источник: `github.com/ComposioHQ/agent-orchestrator`.

### 4. rjmurillo/ai-agents — ближайшая многоролевость, но контрпример по Слою-2 (3-0 / ключевое опровержение 1-2)
23–24 специалиста; оркестратор **маршрутизирует и синтезирует, не исполняет**;
DeepWiki явно делит Decision/Delegation (orchestrator/architect/roadmap/advisors)
vs Execution (implementer/qa/security/devops), и **analyst — цель делегирования, не
постоянная 5-я роль** (эхо идеи профиля).
**Gap:** роли — домен-специализации per-task, **не** детерминированная launch-time
identity, гейтящая эскалацию. Gate = **LLM-критик** (APPROVE/REJECT-цикл), не green
CI → прямой контрпример «Слою-2 сделанному правильно».
Источники: `github.com/rjmurillo/ai-agents`, `deepwiki.com/rjmurillo/ai-agents`.

### 5. Claude Code agent-teams — детерминированный launch-флаг + exit-2 completion-gate (3-0 / 2-1)
«team lead» создаёт команду, спавнит teammates, раздаёт задачи, синтезирует.
Загейчено бинарным флагом `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, **который
агент сам не переключит**. `TaskCompleted` exit-2 = **предотвращает пометку
«выполнено»** (можно прогнать тесты и блокнуть «done» при красном) — форкаемый
детерминированный слот под Слой-2.
**⚠️ Сплит 2-1:** для того же слота есть LLM-вариант (Haiku судит полноту) —
гарантия только у command/exit-2 флавора. Также это **глобальный on/off
возможности**, не per-role identity между разными ролями. Координация локальная
(`~/.claude/tasks/{team}/` + mailbox), **без** GitHub-борда.
Источники: `code.claude.com/docs/en/agent-teams`, `.../hooks`.

### 6. wshobson/agents — «роль» в OSS = домен-специализация, не identity-гейт (3-0)
192 агента / 84 плагина, тиры моделей по доменам. 16 «оркестраторов» — это
workflow-координаторы, **не** launch-time-гейтнутые роли. Нет
dev-assistant/Executor/Task-helper/Tech-lead гейта, нет identity-эскалации, нет
completion-gate. Подтверждает: даже крупнейшая коллекция ролей не содержит нашей
рамки «роль как детерминированная identity».
Источник: `github.com/wshobson/agents`.

---

## Гэп-анализ

- **Закрыто хорошо (форкай):** Слой-1 — натив SDK (deny/allowlist/dontAsk/порядок)
  + gh-aw (capability-split на токене) + liberzon (hardened bash-deny). Это и есть
  «пересечение со security-zero-trust».
- **Закрыто частично:** многоролевость «решает vs исполняет» (rjmurillo) — но без
  identity-гейта; детерминированный completion-gate (ComposioHQ green-CI-boolean,
  agent-teams exit-2) — но в отрыве от ролей и борда.
- **Не закрыто НИКЕМ (= оригинальная часть профиля):**
  1. роль как **детерминированная launch-time identity** (не always-on, не
     глобальный флаг), различающая 4 режима;
  2. **тех-лид-авторство борда** (issues + milestones + sub-issues) **под этим
     гейтом**;
  3. **completion-gate на пруфе без LLM-судьи**, привязанный к закрытию issue;
  4. и главное — **их интеграция в один профиль.**
- **Слой-3** (диспозиция; честное «не чиним»): проект, который **явно** адресует
  «вопрос≠команда / over-eager» и **честно** помечает как non-enforceable, **не
  найден**. Адъяцентные constitution/CLAUDE.md-правила есть, но без честной рамки
  неисполнимости.

---

## «Прямо взять/форкнуть» vs «только идея»

**Форкать (код есть):**
- `gh-aw` safe-outputs → шаблон capped-капабилити для борд-операций тех-лида.
- Agent SDK `deny` + `dontAsk` + bare-name → Слой-1 (identity-split).
- `liberzon/claude-hooks` `smart_approve.py` → закрыть дыру нативного permission'а
  (матч по всей строке: `git status && rm -rf /` проскакивает мимо allow на `git status`).
- ComposioHQ reactions-конфиг (`green CI AND approved` boolean) + agent-teams
  `TaskCompleted` exit-2 → Слой-2 без LLM-судьи.

**Только идея (кода под наш кейс нет):** связка ролей-через-identity +
борд-авторство + completion-gate; честный Слой-3.

---

## Оговорки (из самого отчёта)

- **Снимок на 2026-06-03**; звёзды/коммиты дрейфуют; agent-teams —
  **экспериментальная фича за флагом**, Anthropic может изменить.
- **«Детерминированно» — свойство выбранного флавора хука, не системы хуков в
  целом.** Оба сплита (2-1) ровно про это.
- **Coverage-лимит:** штатный харнесс сжал 8 осей запроса в **5 углов**. Кандидаты
  **ccpm, oss-sprint/oss-kickstart, claude-flow, MetaGPT, ChatDev, OpenHands,
  Sweep, Devika, Aider architect mode** упомянуты лишь вскользь — **их репозитории
  не открывались**. Это отсутствие верификации, не доказательство отсутствия
  механизма.

---

## Рекомендованный второй проход

Самый ценный открытый вопрос: **закрывают ли непроверенные кандидаты (ccpm,
oss-sprint, claude-flow, MetaGPT, ChatDev) связку identity-роль + борд-авторство +
completion-gate?** Они выпали из 5-углового сжатия. Точечный второй проход —
открыть README/код каждого из 5–7 репозиториев и проверить именно три «не закрытых
никем» признака — быстрее и дешевле полного прогона.

Прочие открытые вопросы:
- Воспроизводим ли capability-split gh-aw (read-only агент + отдельный write-job +
  capped safe-outputs) **вне** GitHub Actions — для долгоживущей локальной
  тех-лид-сессии, или он структурно завязан на двухджобную Actions-модель?
- Эмпирический false-negative/false-positive LLM-критик-гейта (rjmurillo) vs
  green-CI-boolean-гейта (ComposioHQ) на конкретном failure mode «агент врёт, что
  готово»? Механизмы есть, сравнительных данных надёжности — нет.

---

## Источники (verified-подтверждённые, primary)

- https://github.com/github/gh-aw + `github.github.io/gh-aw/reference/safe-outputs/`
- https://github.com/ComposioHQ/agent-orchestrator
- https://github.com/rjmurillo/ai-agents + `deepwiki.com/rjmurillo/ai-agents`
- https://github.com/liberzon/claude-hooks
- https://github.com/wshobson/agents
- https://platform.claude.com/docs/en/agent-sdk/permissions
- https://code.claude.com/docs/en/permissions · `/hooks-guide` · `/hooks` · `/agent-teams`
