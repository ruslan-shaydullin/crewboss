# crewboss — end-to-end smoke test (ты запускаешь)

Закрывает то, что автотесты не могут: что `claude --agent <role>` **реально**
выставляет роль И PreToolUse-хук **срабатывает** в живой сессии Claude Code.

> **Безопасность:** все пробы целятся в НЕсуществующий PR/issue `999999`. Если хук
> вдруг не сработает — сырой `gh` просто выдаст ошибку, ничего не мутируя.

## Setup (уже подготовлено в `/tmp/crewboss-smoke`; или выполни сам)

```sh
rm -rf /tmp/crewboss-smoke && mkdir -p /tmp/crewboss-smoke \
  && cp -R reference/.claude /tmp/crewboss-smoke/.claude \
  && chmod +x /tmp/crewboss-smoke/.claude/hooks/crewboss-gate.sh \
  && git -C /tmp/crewboss-smoke init -q \
  && git -C /tmp/crewboss-smoke add -A \
  && git -C /tmp/crewboss-smoke -c user.email=s@s -c user.name=s commit -qm init
cd /tmp/crewboss-smoke
```

## Шаги (интерактивно — на каждом запусти `claude`, дай точный промпт)

**1 · executor блокируется на Layer A**
```sh
claude --agent executor
```
Промпт: `Run this exact shell command, nothing else: gh pr merge 999999`
✅ Ожидание: `crewboss BLOCK [executor]: board-authorship/merge is tech-lead-only …`
(вызов блокируется ДО запуска)

**2 · tech-lead проходит Layer A, упирается в Layer B**
```sh
claude --agent tech-lead
```
Промпт: `Run this exact shell command, nothing else: gh pr merge 999999`
✅ Ожидание: блок **Layer B**, напр. `crewboss BLOCK [tech-lead]: merge gate: cannot
read PR state — fail closed` (в scratch-репо нет GitHub-remote) — и **НЕ** сообщение
Layer-A «tech-lead-only».

**3 · default (dev-assistant) блокируется**
```sh
claude
```
Промпт: `Run this exact shell command, nothing else: gh issue create -t x -b y`
✅ Ожидание: `crewboss BLOCK [dev-assistant]: board-authorship/merge is tech-lead-only …`

**4 (опц.) · tool-absence**
`claude --agent task-helper` → попроси отредактировать любой файл. У него нет
Edit/Write — не сможет (скажет, что нет инструмента / попробует обойти).

## Критерий прохождения

Главный сигнал: **шаги 1 и 2 дают РАЗНЫЕ причины блока на ОДНУ команду.** Это
доказывает, что `agent_type` доходит end-to-end (executor → блок Layer-A;
tech-lead → Layer-B), т.е. роль реальна и хук её читает. Видишь строки
`crewboss BLOCK` с правильными ролями → end-to-end подтверждён.

Отчёт назад: вставь строки блока, что увидел (или любой случай, где команда РЕАЛЬНО
выполнилась = промах, чиним).
