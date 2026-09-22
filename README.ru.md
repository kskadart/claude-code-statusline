[English](README.md) | **Русский**

# claude-code-statusline

[![CI](https://github.com/kskadart/claude-code-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/kskadart/claude-code-statusline/actions/workflows/ci.yml)

Строка состояния для [Claude Code](https://claude.com/claude-code). Она
появляется под чатом при каждом рендере и показывает папку проекта,
стоимость сессии и заполнение окна контекста. Также она показывает расход
5-часового и недельного лимита, время до их сброса, длительность сессии и
часы. Устанавливается одним файлом скрипта и одной строкой в
`settings.json`.

![Скриншот строки состояния](docs/screenshot.png)

## Пример

```
.claude | $0.00 | ctx:0% | 5h:23% (1h39m) | 7d:37% (3d6h) | 6s | 12:30:13
```

Сегмент `+add/-del` появляется только тогда, когда в сессии были
добавлены или удалены строки:

```
myproj | $0.42 | +12/-3 | ctx:18% | 5h:5% (4h51m) | 7d:9% (6d22h) | 3m12s | 09:04:21
```

## Что означает каждый сегмент

| Сегмент | Источник (поле JSON на stdin) | Значение | Цветовые пороги |
|---|---|---|---|
| dir | `workspace.current_dir` | Последний компонент пути; `~`, если он равен `$HOME` | голубой, без порогов |
| cost | `cost.total_cost_usd` | Стоимость сессии на данный момент, `$X.XX` | жёлтый, без порогов |
| `+add/-del` | `cost.total_lines_added` / `total_lines_removed` | Изменённые строки за сессию; скрыт, если оба значения — 0 | зелёный `+`, красный `-` |
| ctx | `context_window.used_percentage` | Заполнение окна контекста | зелёный <70, жёлтый 70–89, красный ≥90 |
| 5h | `rate_limits.five_hour.used_percentage`, `resets_at` | Расход 5-часового лимита и время до сброса (`XdYh` / `XhYm` / `XmYs` / `Xs` / `now`) | зелёный <70, жёлтый 70–89, красный ≥90 |
| 7d | `rate_limits.seven_day.used_percentage`, `resets_at` | Расход недельного лимита и время до сброса | зелёный <70, жёлтый 70–89, красный ≥90 |
| duration | `cost.total_duration_ms` | Длительность сессии по часам | шалфейный, без порогов |
| clock | локальная `date` | Текущее местное время | оранжевый, без порогов |

## Требования

- bash, jq
- curl — нужен только для фолбэка по лимитам на macOS (см. ниже)
- Claude Code с поддержкой `statusLine`
- для разработки: perl, shellcheck, bats

Основной путь (данные из stdin) работает на macOS и Linux. Фолбэк-путь
(см. ниже) — только для macOS: он использует Keychain (`security`) и BSD
`date -j -f`; на Linux он молча пропускается.

## Установка

1. Скопируйте `statusline.sh` в `~/.claude/statusline.sh` и сделайте его
   исполняемым (`chmod +x`).
2. Добавьте в `~/.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 2 }
}
```

## Настройка

- `CLAUDE_STATUSLINE_CACHE_DIR` — куда пишется кэш фолбэка по лимитам.
  По умолчанию: `~/.claude/cache`.

## Как получаются данные о лимитах

1. В первую очередь: поле `rate_limits` в JSON, который Claude Code
   передаёт скрипту через stdin. В актуальных версиях Claude Code этого
   достаточно, больше скрипту ничего не нужно.
2. Фолбэк, только если этого поля нет: скрипт читает OAuth-токен, который
   сам Claude Code хранит в Keychain macOS (элемент
   `Claude Code-credentials`), и запрашивает
   `https://api.anthropic.com/api/oauth/usage` с заголовком
   `anthropic-beta: oauth-2025-04-20`. Ответ кэшируется на 60 секунд в
   файле с правами `600`; таймаут запроса — 2 секунды.

   **Это неофициальный и недокументированный эндпоинт.** Он может
   измениться или исчезнуть без предупреждения. Токен отправляется
   только на `api.anthropic.com` и никуда больше. Если вам это не
   подходит — удалите блок фолбэка из скрипта: путь через stdin
   продолжит работать сам по себе.

## Заметки о реализации

- Скрипт находится на горячем пути — вызывается на каждый рендер.
  Минимум форков; никаких вызовов `git` (информация о ветке намеренно не
  показывается).
- При изменении раскладки сегментов обновите комментарий в шапке
  `statusline.sh`.
- Рабочий каталог самого скрипта — не рабочий каталог сессии: папка в
  выводе всегда берётся из `workspace.current_dir`.

## Разработка

```bash
shellcheck statusline.sh docs/render-screenshot.sh tests/stubs/*
bats tests/
```

Установка инструментов:

```bash
# macOS
brew install shellcheck bats-core

# Debian/Ubuntu
sudo apt-get install -y shellcheck bats
```

Тесты никогда не обращаются к настоящему Keychain или сети:
`tests/stubs/security` и `tests/stubs/curl` — заглушки, подставленные в
начало `PATH`, а `HOME` и `CLAUDE_STATUSLINE_CACHE_DIR` указывают на
временные каталоги для каждого теста. См. `tests/statusline.bats` и
`tests/fixtures/`.

Чтобы перегенерировать `docs/screenshot.png`, запустите
`docs/render-screenshot.sh --render` (флаг `--render` обязателен, чтобы
получить PNG; без него скрипт только запишет `docs/screenshot.html`). Для
рендеринга нужен локальный Chrome или Chromium — если он не определяется
автоматически, укажите `CHROME_BIN`.

## Лицензия

MIT, см. [LICENSE](LICENSE).
