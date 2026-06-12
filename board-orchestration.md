# crewboss — board-orchestration (Arch-2 design)

> Дизайн Арх-2: все хэндоффы через борд, никто не спавнит суб-агентов; воркеры —
> отдельные процессы. Контекст ролей/гейтов — [spec §3](docs/agent-reliability-gating-spec-v0.md).
> **STATUS:** дизайн зафиксирован; **launcher ПОСТРОЕН** (Слайс 1–2: предикат
> `launchable.sh` + цикл `crewboss-launcher.sh` + safety + `--dry-run` + тесты,
> `reference/launcher/`) — **dry-run-verified, не live**. Pending: промпты агентов
> под стейт-машину + live-тест + retry-cap.

## Принцип
`boss → борд → tech-lead → борд → executor`. Каждый воркер — отдельная сессия
(`claude --agent …`), I/O только борд, между собой не общаются. «Запустил-спишь».
Никакого in-session спавна (Арх-1 = антипаттерн: держит человека в няньках).

## State-machine

**Charter** (заводит boss; статус-лейблы):
`needs-plan` → `plan-review` (tech-lead декомпозировал + обоснование) → `approved`
(boss одобрил; или назад в `needs-plan` с замечаниями) → **closed** (когда все дети
закрыты — §5.1).

**Leaf** (sub-issue, заводит tech-lead; статус-лейблы):
open → `in-progress` (claim лаунчера) → `review` (executor открыл PR) → **closed/done**
(PR смержен). Плюс: `blocked` (executor упал после retry-cap → триаж тех-лиду);
`hold` (veto, любой момент, tech-lead/человек); `depends-on:#X` (рёбра графа).

**Launchable (ВЫЧИСЛЯЕТ лаунчер, не хранимый лейбл):**
> parent-charter `approved` **И** все `depends-on:#X` закрыты **И** leaf open
> **И** не {`in-progress`, `review`, `blocked`, `hold`}.

Нет хранимого `ready`/`draft` — готовность derived из объективного состояния (факт,
не самоотчёт). `hold` — явный veto поверх вычисления (для soft-блокеров, что предикат не видит).

## Launcher (poll; plain-скрипт, НЕ vendor-loop)
Каждый тик:
1. **kill-switch** (флаг-файл) → стоп;
2. **budget/rate-cap** исчерпан → стоп + алерт;
3. выбрать launchable (предикат выше), до **concurrency-cap**; **conservative-parallel:**
   параллелить только явно-независимые/непересекающиеся, иначе сериализовать;
4. **claim:** `in-progress` + `claimed-by:<launcher-id>`, перечитать; конфликт → тайбрейк
   (меньший id берёт). Промах безвреден — второй executor коллизит на ветке `task/<id>` и падает;
5. запустить `claude --agent executor <issue>` отдельным процессом в **worktree** (изоляция);
6. на завершении: PR открыт → `review`; провал → retry-cap → `blocked` + коммент;
7. нет launchable → **idle (длинный сон)**, не busy-spin.

Конфиг: poll-interval, concurrency-cap, budget/rate-cap, retry-cap.
Несколько лаунчеров — ок (best-effort claim; либо партиционирование `hash(#) % N`).

## Где гейты
- **plan-approval:** clause «charter `approved`» в предикате лаунчера. Нет аппрува →
  leaf не launchable → executor не стартует. (Под Арх-2 это НЕ гейт спавна — спавна нет.)
- **merge-gate (§5.2):** PR мержится только аппрув-не-автора + green (хук, гвоздь 2).
- **scope-completion (§5.1):** charter закрыть только когда все дети закрыты.
- **ordering:** clause «deps закрыты» в предикате; НЕдекларированные пересечения ловит
  merge-слой (конфликт → rebase-retry, не порча).

## Acceptance (machine)

Каждое issue-лист **обязано** содержать блок `## Acceptance (machine)`.
Без него предикат `launchable.sh` считает лист не готовым к запуску.

### Формат

```
## Acceptance (machine)
- test: <путь к тест-файлу от корня репо>     ← исполняется как `bash <путь>`
- check: <одна shell-команда>
```

**Границы блока:** от строки `## Acceptance (machine)` до следующего `## `-заголовка
(или конца файла). Валидные строки — только `- test: …` и `- check: …`; минимум одна.

### Трансляция (acceptance-parse.sh)

`reference/runtime/acceptance-parse.sh` принимает тело issue (stdin или файл) и
выводит исполняемые проверки по одной на строку:
- `- test: <путь>` → `bash <путь>`
- `- check: <cmd>` → `<cmd>` (как есть)

Тело без валидного блока → ненулевой exit.

### Гейт в предикате

`proto/r6/launchable.sh` и `reference/launcher/launchable.sh` содержат jq-функцию
`has_acceptance_block`, которая структурно проверяет наличие заголовка и хотя бы одной
валидной строки. Лист без блока → не попадает в launchable-множество → executor не
стартует. Полную трансляцию и исполнение проверок выполняет хелпер.

## Честные caveats
- **Лаунчер un-gated** (гвозди гейтят воркеров ВНУТРИ сессий, не «что запускать») → его
  безопасность = его caps/kill-switch/тесты. **Держать маленьким.** Чем больше политики
  он вычисляет, тем больше негейченного «мозга».
- **Доверие на `depends-on`** (декларирует tech-lead, ревьюит boss в плане) — не ноль.
- **Claim best-effort** — промах безвреден (ветка `task/<id>` уникальна).
- **Коллизия = retry, не порча** (git — бэкстоп). Рычаг — качество декомпозиции (апстрим)
  + рабочий rebase-retry, НЕ умные dep-алгоритмы (оверинжиниринг на v0).
- Качество системы = качество описания таск: executor холодный, видит только issue →
  **issue обязана быть самодостаточной.**
