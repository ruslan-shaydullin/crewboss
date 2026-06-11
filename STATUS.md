# crewboss — STATUS (snapshot)

> Точка возобновления. Полный roadmap — [spinout-plan](docs/agent-reliability-gating-spinout-plan.md);
> дизайн — [spec](docs/agent-reliability-gating-spec-v0.md). Обновлено: **2026-06-04**.

## Где живёт
- Свой приватный репо: **`stratch1989/crewboss`** (спин-аут 2026-06-11 из Quarter,
  снимок ветки `crewboss` @ `942149d`; полная история инкубации — там).
- Спека / ресёрч / план: `docs/*.md`. Референс: `reference/`. UI: `ui/`.
- Инкубируем приватно (план F1); публичным делаем к релизу. Имя: **crewboss** (F2).
- Догфуд: разработка crewboss ведётся самим crewboss (борд = issues этого репо).

## Сделано и провалидировано ✅
- **Спека v0**: 3 слоя, роли (dev-assistant default + executor/task-helper/tech-lead/boss/analyst), proof-контракт §5.1/§5.2, honest enforcement-ceiling.
- **Reference**: identity (`--agent` + `tools:`) + центральный хук `crewboss-gate.sh`
  (Layer A role-gating + Layer B proof-gates, ветвление по `agent_type`).
- **Тесты**: Layer-A харнесс (рос 15→22→25→31→**46**, вкл. in-model-canon + `${IFS}`-boundary + false-deny guards);
  Layer-B харнесс **20/20** (стабит `gh` → merge §5.2 / ready §5.2 / close 5-rule §5.1, все ветки + fail-closed);
  **end-to-end live** (CC v2.1.162): `--agent` грузит роль, хук держит детерминированно мимо «авторизации» модели.
- **Роль `boss`** (выше тех-лида; code-blind + exec-blind): agent + ветка хука + тесты (харнесс 22/22).
- **Арх-2 (board-async) дизайн** зафиксирован → `board-orchestration.md` (две плоскости, state-machine, gates).
- **Launcher построен** (Слайс 1–2, `reference/launcher/`): предикат `launchable.sh` + цикл `crewboss-launcher.sh` + safety + retry-cap + `--dry-run`. **Integration-тест `launcher-integration.test.sh` 10/10** — реальный git-репо + стабы `claude`/`gh`: claim→launch→handle_result→label цикл, retry-cap→blocked, и **data-loss фикс эмпирически доказан** (против `-B`-версии scenario B падает на data-survival — тест не тавтология).
- **LIVE-прогон сделан** (2026-06-04, репо `stratch1989/crewboss-live`, см. `reference/live/`): лаунчер → **реальный `claude --agent executor`** → реальный код+commit → **реальный PR** (#4/#5 open) → issue `status:review`; executor остановился на PR (не мержит). Merge-гейт проверен на **живом PR**: tech-lead `gh pr merge` без аппрува → DENY (§5.2), обфусцированный `gh pr "merge" --admin` → canon свернул → DENY, executor merge → role-DENY. Находка прогона: unattended `-p` требует `permissions.allow` (иначе стопор на approve), фикс `df5c5a9`. **НЕ покрыто (нужны не мои руки):** allow-path merge (approved+green→проходит, нужен 2-й ревьюер) + server-side branch protection (на private free-плане недоступен).
- **Агенты выровнены под Арх-2** (tech-lead без спавна: фаза-план + ревью/мерж; boss аппрув-флип) + **`analyst`**-роль. → Layer-A = **friction-gate**: `canon()` сворачивает внутри-модельные варианты к литералу (кавычки/`command`/path/global-flags/`gh api`-merge-close → `deny`); слипает только намеренная evasion (`${IFS}`/`$VAR`/`eval`/alias — adversarial, **вне модели**). Твёрдые якоря — tool-absence + branch protection (+`--admin` бьёт BP → require-admins).
- **Red-team-свип-1** (un-correlated): нашёл+закрыт **Batch A** (compound-chaining/whitespace/boss newline+redirect+git-log/charter-anchor/worktree-rc/retry) + **Batch B** (Арх-2-рассинхрон, analyst, plan-approval=built, scoped over-claims).
- **Red-team-свип-2** (un-correlated, 10 линз, 35 находок): поймал, что «Layer-A-complete/31/31» был **over-claim** — верб-гейт пробивается ~8 обфускациями (подтверждено руками). **Batch D** закрыт: ретракт over-claim'ов (STATUS/README/спека/gate-header → «friction-gate, не enforced») + внутри-модельные баги — worktree-data-loss (`-B` force-reset → reuse-no-reset), uninstall-foreign-hook-wipe (per-command filter), task-helper-doc-ложь, spec chat-phrase→`--agent`. Гонку за `${IFS}`/`eval`/`alias` НЕ ведём (вне модели).
- **Batch E** (свип-2 follow-up): закрыты два главных пробела. (1) **`canon()`-токенизация гейта** — внутри-модельные верб-варианты (кавычки, `command`/path-префикс, gh global-flags, `gh api` merge/close) теперь сворачиваются к литералу и `deny`; `${IFS}`/evasion явно вне модели (header SCOPE + boundary-тест). (2) **Layer-B executable-харнесс 20/20** — стабит `gh`, покрывает merge/ready/close пруф-контракт (раньше 0 автотестов — ядро гвоздя-2 без регресс-лока). Layer-A 31→**46**. Без новых false-deny (guard-тесты: api-GET, gated-слово-в-значении, flag+read → allow).
- **Доки + UX (релиз-трек):** англ. project README + англ. перевод спеки (`...spec-v0.en.md`) + рус. гайд (`guide.ru.md`) + UX-роадмеп. **UX P0+ядро P1 РЕАЛИЗОВАНЫ:** `crewboss` CLI (`reference/bin/crewboss`: init/doctor/status/approve/run/роли/try/teardown, smoke **15/15**) — `init` ставит `permissions.allow` by default (грабля unattended исчезает); читаемый прогресс лаунчера со сводкой (`▶/✓/↻/✗` + `cycle done: N review · …`). Полный сьют **46/20/launchable/9/10/15**.

## Следующие шаги
**Дёшево / dogfood:**
- [x] ~~Промпты boss/tech-lead под стейт-машину~~ — сделано (`4fd524d`); `analyst` + retry-cap — `d826b96`.
- [x] ~~**Live-тест лаунчера**~~ — СДЕЛАН: реальный executor→PR→review + merge-гейт на живом PR (см. «Сделано»). Остаток (allow-path merge + server BP) нужен 2-й аккаунт / платный план.
- [ ] Тест на Quarter (изолированный клон `/tmp/crewboss-quarter`, реальный remote) — блок/allow на живых PR/issue.
- [x] ~~Капстоун: tech-lead allow-path~~ — покрыт Layer-B харнессом (m1 merge-approved+green, c1/c4/c5 close — tech-lead → allow).
- [ ] Policy-доделки хука: milestone-авторство, push-таргеты (TODO в коде).

**Release-стадия:**
- [ ] Happy-path мутационный merge (внешний репо + branch protection + 2-й ревьюер).
- [ ] Английская версия спеки + README.
- [ ] Публичный репо (хэндл-вариант, plan F2) + LICENSE + демо-запись.
- [ ] Дистрибуция: awesome-claude-code, Anthropic Discord, пост (security→reliability).
- [ ] Эмпирика «гейт снижает false-done» (spec OQ#2 — не измерено).

## Как возобновить
`git checkout docs/roles-gating-oss-research`; читать этот файл + plan §3 (воркстримы).
Smoke-тест: `reference/tests/smoke-e2e.md`.

## Лог (ветка)
research → spec → plan → naming → reference chunk-1/2 → Layer-A harness → Layer-B live →
end-to-end → boss role → board-orchestration design (Арх-2) → launcher slice 1–2.
(`git log docs/roles-gating-oss-research`)
