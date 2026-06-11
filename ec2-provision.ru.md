# EC2-провижининг crewboss-хоста — полный список операций

> Снято с живого бокса 2026-06-10 (всё ниже реально выполнялось при его настройке).
> Это скелет будущего `crewboss provision` (см. design §4.7). Разметка шагов:
> **[auto]** — скриптуется без человека · **[interactive]** — нужен человек один раз ·
> **[aws]** — AWS-слой (консоль или aws cli с креденшелами).

## 0. AWS-слой

1. **[aws]** Инстанс: Amazon Linux 2023, x86_64, класс **t3.xlarge** (4 vCPU / 16 ГБ), диск **70 ГБ gp3**. AMI — стоковый AL2023 (user-namespaces включены из коробки, `max_user_namespaces≈62k` — проверяется в doctor, не настраивается).
2. **[aws]** Security group: inbound — только SSH (22/tcp) с IP оператора; outbound — открыт (фильтрация egress — забота jail-прокси, не SG).
3. **[aws]** Key pair → `~/.ssh/<key>.pem` у оператора (текущий: `NewOne.pem`).
4. **[aws]** **Elastic IP — обязательно** (выделить + привязать). Без него публичный IP меняется на каждом stop/start, отваливаются SSH-конфиги и всё, что захардкодило адрес. (Текущий бокс: EIP `3.217.199.168` повешен 2026-06-10.) С фев-2024 любой публичный IPv4 платный (~$3.6/мес) — EIP не дороже динамического, просто статичный.
5. **[aws]** (опц.) IMDSv2-метаданные доступны только с токеном — скрипту, которому нужен instance-type/region, использовать `ec2-metadata` или token-flow, голый `curl 169.254.169.254` молчит.

## 1. Базовая ОС

6. **[auto]** `sudo dnf -y update`
7. **[auto]** Базовый тулчейн: `sudo dnf -y install git jq tar` (python3 3.9 уже в AL2023 — на нём работают `proxy.py`/`bridge.py`, отдельно ставить не надо).
8. **[auto]** Build-deps для nsjail: `sudo dnf -y install gcc gcc-c++ make autoconf bison flex libtool pkgconf-pkg-config protobuf-devel protobuf-compiler libnl3-devel`

## 2. nsjail (из исходников — в репах AL2023 его нет)

9. **[auto]** `git clone https://github.com/google/nsjail.git /tmp/nsjail-src && make -C /tmp/nsjail-src -j$(nproc) && sudo install -m 755 /tmp/nsjail-src/nsjail /usr/local/bin/nsjail && rm -rf /tmp/nsjail-src`
10. **[auto]** Смоук: `nsjail -Mo --disable_clone_newnet -R /usr -R /bin -R /lib -R /lib64 --really_quiet -- /bin/true; echo $?` → 0.

## 3. Node (для Expo-гейта Quarter, НЕ для claude)

11. **[auto]** Nodesource-репо + node: текущий бокс — node 18 (`nodesource-nodejs.repo`), целевой — **20** (Expo-гейт): `curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash - && sudo dnf -y install nodejs`

## 4. gh CLI (в репах AL2023 нет — официальный репо GitHub)

12. **[auto]** `sudo dnf -y install dnf-plugins-core && sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && sudo dnf -y install gh` (на боксе: gh 2.93).
13. **[interactive]** Авторизация: сейчас `gh auth login` (web-flow, один раз). Целевое состояние по design §11 — **fine-grained PAT** только на рабочие репо в `GH_TOKEN`: тогда шаг становится **[auto]** (секрет передаётся при провижининге), а `gh auth login` не нужен вовсе.

## 5. claude CLI

14. **[auto]** Нативный инсталлер: `curl -fsSL https://claude.ai/install.sh | bash` → кладёт версию в `~/.local/share/claude/versions/<ver>` + симлинк `~/.local/bin/claude` (Bun-бинарь; node ему не нужен). Убедиться, что `~/.local/bin` в PATH.
15. **[interactive]** `claude setup-token` → OAuth-токен подписки (refresh ~1 год). Записать в `~/.crewboss.env`:
    `export CLAUDE_CODE_OAUTH_TOKEN=...` и **`chmod 600 ~/.crewboss.env`** (инсталлятор этого не сделает; на текущем боксе файл успел полежать с 644 — doctor должен проверять права).
16. **[interactive→auto]** Первый headless-прогон (он же создаёт `~/.claude.json` — отдельный ФАЙЛ рядом с папкой `~/.claude`, оба нужны jail'у; и триггерит одноразовый «usage approval» если есть):
    `source ~/.crewboss.env && claude -p "Reply with exactly: OK" --output-format json`
    Проверить: в ответе `"result":"OK"` и `total_cost_usd`. **`ANTHROPIC_API_KEY` нигде не задавать** — он приоритетнее OAuth и уведёт на платный API.

## 6. git-идентичность и артефакты crewboss

17. **[auto]** `git config --global user.name/user.email` (бот-идентичность для floor-коммитов).
18. **[auto]** Развернуть сетевые скрипты jail'а из репо: `proto/net/` → `~/cbnet/` (proxy.py, bridge.py, jail-test.sh, run-net1..4.sh; канон — в гите, `/tmp` на боксе сгорает при reboot).
18a. **[auto]** Развернуть seccomp-политику: `proto/seccomp/claude.kafel` → роль-профиль. **Грабля:** kafel-таблица amd64 в этой сборке nsjail не знает `stat/fstat/lstat/sendfile/uname` — они заданы числами `SYSCALL[4,5,6,40,63]`. При апгрейде nsjail/claude пере-снять syscall-поверхность (`run-sc-discover3.sh` → `find-unknown.sh` → `run-sc-policy2.sh`), т.к. список may drift.
19. **[auto]** (боевой лаунчер, по design §4.5) Каталоги: зеркало `git clone --mirror` рабочего репо + `run/work/` — **на одной ФС** (один `st_dev`), `run/` под `flock`-файлы (`launcher.lock`, `mirror.lock`).

## 7. Валидация (та же лесенка, что при ручной настройке)

20. **[auto]** `bash ~/cbnet/run-net1.sh` → в `net1.out`: только `lo`, `rc=6/7/2` на egress/DNS, `lo-ok`.
21. **[auto]** `bash ~/cbnet/run-net2.sh` → все ALLOW-хосты отвечают, BLOCK-тесты дают `DENY` в `proxy.log`.
22. **[auto]** `bash ~/cbnet/run-net3.sh` → claude-смоук `"result":"OK"` через прокси (~$0.026).
23. **[auto]** `bash ~/cbnet/run-net4.sh` → git clone+push изнутри jail через прокси (нужен throwaway-репо).

## 8. doctor-инварианты (hard-fail, по design §4.7)

- Linux + user-namespaces (`/proc/sys/user/max_user_namespaces` > 0) — **hard-fail**, не warn.
- `/usr/local/bin/nsjail` есть и запускается; toolchain: git, jq, gh, node, python3, claude.
- **seccomp-политика парсится** (`nsjail --seccomp_policy <role>.kafel -- /bin/true` без `Couldn't prepare sandboxing policy`) — иначе jail без «третьего гвоздя».
- `CLAUDE_CODE_OAUTH_TOKEN` задан, **`ANTHROPIC_API_KEY` пуст**.
- `~/.crewboss.env` — права **600**; `~/.claude.json` (файл) и `~/.claude` (папка) существуют.
- gh аутентифицирован (`gh auth status` / валидный `GH_TOKEN`).
- Зеркало и `run/work/` на одной ФС; push-URL рабочего репо резолвится в github.com.
- Нет второго лаунчера (`flock run/launcher.lock`).

## Известные «не сделано» на текущем боксе

- ~~Elastic IP не привязан~~ — СДЕЛАНО (`3.217.199.168`, 2026-06-10).
- node 18, не 20 (шаг 11) — поднять перед Expo-гейтом.
- gh на web-flow оператора, не fine-grained PAT (шаг 13).
