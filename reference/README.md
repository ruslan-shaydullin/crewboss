# crewboss — reference implementation (v0, DRAFT)

Drop-in Claude Code config реализующий паттерн **crewboss** (reliability-gating для
кодящих агентов). Спека: [`../docs/agent-reliability-gating-spec-v0.md`](../docs/agent-reliability-gating-spec-v0.md).

> **Pinned: Claude Code v2.1.161** — механики выверены по докам на этой версии.
> Фичи стабильны (не за флагами). На других версиях — перепроверять.

## Архитектура — два слоя (= два гвоздя)

1. **Роль = launch-time identity** (`claude --agent <name>`) + **`tools:`-allowlist** в
   agent-файле. Нет инструмента в наборе роли → агент его не видит. Это **единственный
   локальный слой, держащий даже против `bypassPermissions`.**
2. **Командный уровень + completion-gates = центральный PreToolUse-хук**, ветвящийся по
   stdin-полю **`agent_type`** (несёт имя `--agent`). Гейтит «эта роль может `gh pr merge`,
   та — нет» и пруф-контракт (§5.1/§5.2 спеки). **← реализовано в `hooks/crewboss-gate.sh` (draft).**

## Роли (как запускать)

| Запуск | Роль | Инструменты (tool-absence = hard) |
|---|---|---|
| `claude` (без флага) | **dev-assistant** (default) | Read/Edit/Write/Bash; нет Agent |
| `claude --agent executor` | **Executor** | Read/Edit/Write/Bash; **нет Agent** (спавнить не может) |
| `claude --agent task-helper` | **Task-helper** | Read/Bash; **нет Edit/Write** (код не трогает) |
| `claude --agent tech-lead` | **Tech-lead** | Read/Bash; **нет Edit/Write/Agent** — под Арх-2 не спавнит (executor'ов запускает лаунчер); декомпозит + ревью/мерж |
| `claude --agent boss` | **boss** (стратег, выше тех-лида) | **только Bash** (gh-чартеры) + хук-роллл; **нет Read/Edit/Write/Agent** — code-blind + exec-blind, чартерит тех-лиду |
| `claude --agent analyst` | **analyst** (research, цель делегирования) | Read/Bash (read-only); **нет Edit/Write/Agent** — расследует, постит findings-дайджест, кода не меняет |

Уже на этом слое tool-absence даёт твёрдые границы: спавнить может только tech-lead;
код руками не трогают tech-lead и task-helper. Различия по **gh-подкомандам**
(merge / issue create / close, push-таргеты) — на командном уровне → chunk-2 (хук).

## Честный потолок enforcement (читать)

- **Твёрдо против `bypassPermissions`:** только tool-absence (`tools:`) и server-side
  GitHub branch protection (merge-гейт, §5.2 спеки).
- **settings-`deny` и PreToolUse-хук детерминированы, но обходятся** человеческим
  `--dangerously-skip-permissions`. **Агент сам в этот режим не войдёт** (launch-выбор
  человека) → для threat-model reliability (не security) достаточно. Но мы это говорим
  прямо, а не прячем.
- **Командный хук — friction, не enforcement.** `canon()` сворачивает **внутри-модельные**
  варианты к литералу (кавычки `gh pr "merge"`, `command`/`/path/gh`, global-flags
  `gh -R o/r pr merge`, REST `gh api …/pulls/N/merge`) → они тоже `deny`. Слипает только
  **намеренная evasion** (`gh${IFS}pr…` / `$VAR` / `eval` / alias) — adversarial, вне модели
  (агент ленив, не злонамерен); гонку за ней не ведём. push не гейтим (якорь — branch
  protection). `gh pr merge --admin` пробивает branch protection → включать **require-admins**.

## Установка (для своего репо)

Скопировать `.claude/` (agents + settings.json + hooks) в корень своего репо;
`chmod +x .claude/hooks/crewboss-gate.sh`. Нужны `jq` и `gh` (auth). Запускать роль
явным `--agent`. Для merge-гейта включить GitHub **branch protection** (§5.2 спеки:
require approvals + required checks + up-to-date + dismiss-stale-approvals) — это
серверный якорь, который держит даже там, где локальный хук обходится bypass.

## Решение «два лаунчера» (tech-lead 2026-06-11, reversible)

| Лаунчер | Статус | Расположение |
|---|---|---|
| `crewboss-launcher-gh.sh` | **CANONICAL** (боевой) | `_box-snapshot/cbnet/`→`reference/runtime/` (#65) |
| `crewboss-launcher.sh` | **LEGACY** (Arch-2 ref) | `reference/launcher/crewboss-launcher.sh` |

Боевой лаунчер работает через GitHub-board (issues+labels), поддерживает фоновый параллелизм
и kill-switch флаг (`run/kill_switch`). Arch-2-референс (worktree+foreground, kill-файл
`.crewboss-launcher.stop`) остаётся в `reference/launcher/` пока тесты `launcher-*.test.sh`
не перенесены на gh-версию. **НЕ УДАЛЯТЬ** legacy-файл — тесты зависят от него.

Runtime-манифест: `reference/runtime-manifest.tsv` (sha256 + статус canonical/pending-backport).

## Статус

- **chunk-1:** identity/tool-слой — **5 agent-файлов** (executor/task-helper/tech-lead/boss/analyst) + dev-assistant default + базовый `settings.json`. ✅
- **chunk-2:** центральный `hooks/crewboss-gate.sh` — per-role командный гейт (Layer A) +
  merge / close / «ready» пруф-гейты (Layer B) по `agent_type`. ✅
- **Тесты:** Layer-A харнесс — **46/46** ✅ (буквальная команда + whitespace/chaining-негативы
  + in-model-обфускация `canon()`: кавычки/global-flags/`command`/path/`gh api`; + boundary-кейс
  `${IFS}` как документированный non-goal; + false-deny guards). Layer-B харнесс — **20/20** ✅
  (стабит `gh`, гоняет merge §5.2 / ready §5.2 / close 5-rule §5.1 — все ветки вердикта,
  вкл. fail-closed). НЕ покрыто исполняемо: happy-path live-merge на реальном branch protection.
- **End-to-end (live, Claude Code v2.1.162):** `--agent` грузит роль (баннер `@executor`) ✅;
  PreToolUse-хук **срабатывает детерминированно** — `gh issue create` под dev-assistant
  перехвачен `crewboss BLOCK` до выполнения, **дважды**, не обходится «авторизацией» модели ✅.
- **НЕ проверено:** happy-path мутационный merge (реальный approval+green → merge проходит) —
  нужен внешний репо + 2-й ревьюер (воркстрим H). Наименее рисковая часть (over-block безопаснее over-allow).
