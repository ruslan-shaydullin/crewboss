# crewboss — как этим пользоваться (гайд)

Практическая инструкция «с нуля до автономного цикла». Концепция и дизайн — в
[README](README.md) и [спеке](docs/agent-reliability-gating-spec-v0.md); здесь — **как работать руками**.

> Коротко: crewboss не даёт кодящему агенту врать «готово» и делать лишнее. Он гейтит
> **опасные действия** (merge / close / спавн) и **заявления о готовности** детерминированно —
> по пруфу (аппрув + зелёный CI / смерженный PR), а не по слову агента. Модель угроз — агент
> **ленив, не злонамерен**.

---

## 1. Установка (один раз на репо)

**Быстро — через `crewboss` CLI** (лежит в `reference/bin/crewboss`; добавь в PATH или зови по пути):
```bash
./reference/bin/crewboss init      # .claude/ (роли + хук) + settings.json с permissions.allow + лейблы — одной командой
./reference/bin/crewboss doctor    # пре-флайт: deps, auth, конфиг, лейблы, branch protection — печатает, что починить
```

**Или вручную** (ровно это `init` и делает):
```bash
# из корня своего репозитория
cp -r <crewboss>/reference/.claude .            # роли (agents) + хук
chmod +x .claude/hooks/crewboss-gate.sh
```

В `.claude/settings.json` пропиши хук **и** allowlist инструментов:

```json
{
  "permissions": { "allow": ["Bash", "Edit", "Write", "Read"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/crewboss-gate.sh" } ] }
    ]
  }
}
```
- `permissions.allow` нужен, чтобы **unattended-режим не стопорился** на запросе разрешения
  (см. §6). Хук всё равно главнее — он в eval-порядке `hooks → deny → mode → ask → allow` идёт
  первым, и его `exit 2` бьёт поперёд любого allow.
- Нужны `jq` и `gh` (с auth). Для merge-якоря включи **branch protection** (§5).

Проверка, что всё на месте:
```bash
bash <crewboss>/reference/tests/gate-layer-a.test.sh   # ожидаем passed=46
bash <crewboss>/reference/tests/gate-layer-b.test.sh   # ожидаем passed=20
```

---

## 2. Модель в голове: две плоскости + борд

Всё крутится вокруг **двух плоскостей**, граница между ними — задача (GitHub Issue):

- **Разговорная** (синхронно, ты в чате):
  - **dev-assistant** — дефолт, просто `claude` без флага. «Сделай вот это сейчас». В борд не лезет.
  - **boss** — «решаем ЧТО делать» → заводит **чартер** (issue-цель). Code-blind + exec-blind.
- **Исполнительная** (асинхронно, борд = вход/выход, «запустил и спишь»):
  - **tech-lead** — декомпозит чартер на задачи, ревьюит и мержит **одобренное**.
  - **executor** — берёт одну задачу → ветка → PR → стоп. Лаунчер запускает их как отдельные процессы.
  - **analyst** — read-only расследование, постит findings-дайджест.
  - **task-helper** — заполняет человеческие задачи (комменты/лейблы), код не трогает.

**Роль выбирается флагом `--agent` на запуске, а не фразой в чате.** Нет флага = dev-assistant.
Это и есть «гвоздь 1»: нельзя «уговорить» сессию стать тех-лидом — у неё физически нет его инструментов.

---

## 3. Кого когда запускать

| Команда | Роль | Для чего |
|---|---|---|
| `claude` | dev-assistant | повседневная помощь по коду, тут и сейчас |
| `claude --agent boss` | boss | поставить цель → чартер тех-лиду |
| `claude --agent tech-lead` | tech-lead | декомпозиция, ревью, мерж одобренного |
| `claude --agent executor` | executor | сделать одну конкретную задачу → PR (обычно запускает лаунчер) |
| `claude --agent analyst` | analyst | разобраться/проанализировать, без правок кода |
| `claude --agent task-helper` | task-helper | закрыть человеческую задачу на борде |

`crewboss <роль>` — короткий алиас (`crewboss boss` = `claude --agent boss`). Плюс командный борд:

| Команда CLI | Что делает |
|---|---|
| `crewboss status` | дашборд борда: чартеры / launchable / в работе / на ревью / blocked |
| `crewboss run [--once \| --dry-run]` | запустить лаунчер |
| `crewboss approve #N` | одобрить план чартера (`plan-review → approved`) |
| `crewboss doctor` | проверить установку |
| `crewboss try` / `teardown` | поднять / снести живую песочницу |

---

## 4. Сценарии (рецепты)

### Сценарий A — просто помощник
Ничего настраивать не надо: `claude`. Это dev-assistant — пишет код в своей ветке, открывает
свой PR. Не грумит борд, не мержит, не спавнит. Хук молча пропускает всё, кроме gated-действий.

### Сценарий B — автономный цикл (сердце crewboss)

```
boss ──charter──▶ борд ──tech-lead декомпозит──▶ leaf-задачи ──boss аппрувит план──▶
   лаунчер запускает executor'ов ──▶ PR'ы ──tech-lead ревью+мерж──▶ закрытие (по пруфу)
```

1. **Поставить цель (boss).**
   ```bash
   claude --agent boss
   # «Заведи чартер: <что хотим получить>»
   ```
   boss создаёт issue с меткой `type:charter` (статус `status:needs-plan`). Он умеет ТОЛЬКО
   заводить/комментить issue и читать борд — ни кода, ни мержа (так держится граница).

2. **Декомпозиция (tech-lead).**
   ```bash
   claude --agent tech-lead
   # «Возьми чартер #N, разбей на задачи»
   ```
   tech-lead создаёт leaf-issue с `Charter: #N` в теле, переводит чартер в `status:plan-review`.

3. **Одобрить план.** Глянь декомпозицию и переведи чартер в `status:approved`
   (`gh issue edit N --add-label status:approved --remove-label status:plan-review`, или попроси boss).
   **Пока чартер не approved — лаунчер его leaf-задачи не возьмёт** (это и есть enforce плана:
   запускается только одобренное).

4. **Запустить исполнителей (лаунчер).**
   ```bash
   # сухой прогон — посмотреть, что планируется запустить, ничего не трогая:
   bash reference/launcher/crewboss-launcher.sh --once --dry-run
   # боевой однопроходный — поднимает реальный executor на каждую launchable-задачу:
   bash reference/launcher/crewboss-launcher.sh --once
   # непрерывный цикл (poll → запуск → пауза), пока не выключишь:
   bash reference/launcher/crewboss-launcher.sh
   ```
   Каждый executor: ветка `task/<id>`, пишет код, открывает PR `Closes #<id>`, **останавливается
   на ревью** (мержить ему хук запрещает). Issue переходит `in-progress → review`.

5. **Ревью и мерж (tech-lead).**
   ```bash
   claude --agent tech-lead
   # «Проверь и смержи PR #X»
   ```
   Хук пропустит мерж **только если** PR одобрен не-автором **и** CI зелёный на head-SHA (§5.2 спеки).
   Нет аппрува или красный CI → `crewboss BLOCK ... merge gate`. Закрытие issue — тоже по пруфу (см. §5).

> Что ещё НЕ построено: Stop-гейт на «доделанность скоупа» (чтобы агент не сказал «готово» при
> живых под-задачах) — спроектирован, но не реализован. Сейчас «доделанность» держится правилом
> закрытия issue (нельзя закрыть родителя с открытыми детьми).

### Сценарий C — разовое расследование
```bash
claude --agent analyst
# «Разберись, почему X; запиши вывод комментом-дайджестом»
```
analyst только читает + комментит. Чтобы закрыть его issue, в комменте должен быть маркер
`crewboss-digest` (иначе хук не даст закрыть — пруф, что работа реально сделана).

---

## 5. Лейбл-машина состояний

| Лейбл | Значит |
|---|---|
| `type:charter` | issue-цель от boss (ось декомпозиции) |
| `type:agent` | задача для executor'а |
| `type:human-*` | задача для человека (хук НЕ даст агенту её закрыть) |
| `status:needs-plan` → `plan-review` → `approved` | жизненный цикл чартера |
| `status:in-progress` | взято лаунчером (executor работает) |
| `status:review` | PR открыт, ждёт ревью |
| `status:blocked` | исчерпан retry-cap, нужен тех-лид |
| `status:hold` | вето: не запускать |

**Launchable** (что возьмёт лаунчер) — это не хранимый лейбл, а **вычисляемое** условие: задача
открыта, под approved-чартером, зависимости (`Depends-on: #X`) закрыты, нет `in-progress/review/blocked/hold`.
Факт, а не самоотчёт.

**Закрытие issue (`gh issue close`) — единственный чокпоинт**, и хук пускает его только по 5 правилам
(§5.1 спеки): human-owned → нельзя (закрывает человек); есть открытые дети → нельзя; leaf со
смерженным PR → можно; analysis-issue с `crewboss-digest`-дайджестом → можно; родитель со всеми
закрытыми детьми → можно; иначе → нельзя.

---

## 6. Что гейты ловят, а что — нет (честно)

**Держат твёрдо (даже против `--dangerously-skip-permissions`):**
- **tool-absence** — нет инструмента в роли → действие физически недоступно (executor не спавнит,
  task-helper не правит код).
- **server-side branch protection** — мерж в защищённую ветку без аппрува/чеков сервер не пустит.

**Friction (детерминированно, но обходится намеренной evasion — и это by design):**
- Командный хук режет gated-вербы (`merge`/`close`/`ready`/спавн) по роли и пруфу. Ловит и
  внутри-модельные варианты: кавычки, `command`/путь, global-flags, `gh api` для merge/close.
- **НЕ ловит** `${IFS}` / `$VAR` / `eval` / alias — это adversarial-evasion, вне модели (агент
  ленив, не злонамерен). Гнаться за этим — проиграть гонку; мы прямо это пишем.

**Совсем не enforce'им:** диспозицию (вопрос≠команда, самохвальство). Только промптами/тренировкой.

---

## 7. Траблшутинг (грабли, проверено на live-прогоне)

- **Unattended `claude -p` ничего не делает / «blocked pending approval».** Нет `permissions.allow`
  в settings.json → каждый инструмент стопорится на запросе разрешения, а ответить в headless
  некому. Лечение — allowlist из §1 (хук остаётся гейтом).
- **Свежий worktree спрашивает trust?** Нет: `claude -p` отключает folder-trust. (Только флаг
  `--worktree` требует доверия заранее — лаунчер его не использует.)
- **Лаунчер запустился и сразу вернул prompt, PR нет.** Значит executor'ы упали мгновенно — почти
  всегда это та же проблема `permissions.allow`. Глянь комменты на issue: там будет
  `executor failed ... retry`.
- **Коммит «не проходит», молча остаётся staged.** commitlint реджектит subject длиннее ~70
  символов. Сделай subject короче, детали — в тело (`-m "..."`).
- **`gh repo delete` ругается на scope.** `gh auth refresh -s delete_repo`, потом удаляй.
- **Branch protection не ставится на private-репо.** На free-плане это платно — сделай репо public
  для теста, или включай BP на платном/организационном.

---

## 8. Живая песочница (попробовать целиком)

Готовый скрипт поднимает изолированный репо на GitHub с чартером + двумя задачами + конфигом:
```bash
bash reference/live/setup-live.sh           # создаёт private-репо + issues + конфиг
# дальше — по reference/live/README.md: dry-run → --once → проверка merge-гейта
```
Снести:
```bash
gh auth refresh -s delete_repo
gh repo delete <owner>/crewboss-live --yes && rm -rf ~/crewboss-live
```

---

Дальше по UX (как сделать это удобнее) — см. [ux-roadmap.ru.md](ux-roadmap.ru.md).
