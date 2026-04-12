# NetMonitor — macOS Menubar Monitor

## Основное
- **Repo**: `~/apps/NetMonitor/` → https://github.com/mxxkss/NetMonitor
- **Язык**: Swift, single-file (`Sources/main.swift`, ~800 строк)
- **Билд**: GitHub Actions (`build.yml`) + локальный `build.sh`
- **Установка**: `Install NetMonitor.command`

## Что показывает
- **Menubar**: скорость сети (up/down) + дата (Пн 12 Апр)
- **Dropdown меню**:
  - Календарь (NSDatePicker, 310x260)
  - CPU sparkline по ядрам + общий %
  - RAM used/total
  - Battery level/charging/cycles/health
  - Wi-Fi SSID + RSSI + signal bars
  - Disk usage
  - Uptime
  - External IP + флаг страны (GeoIP via ipapi.co)
  - Local IP
  - Network traffic total (In/Out)
  - Claude usage (5h / 7d) — через sessionKey cookie или Claude Code OAuth
  - OpenAI status — валидация ключа через /v1/models
  - Terminal / Activity Monitor quick launch

## Keychain
- Service: `team.skazka.netmonitor`
- Keys: `sessionKey` (Claude), `orgId` (Claude, auto-detected), `openai-key`

## Таймеры
- Tick: 2 сек (сеть, CPU, RAM, батарея, Wi-Fi, диск)
- GeoIP + Claude + OpenAI: 600 сек (10 мин)
- Claude: 120 сек

## Архитектура
Всё в одном файле `main.swift`:
- Функции сбора данных (network, CPU, memory, disk, wifi, battery)
- `renderStatusImage()` — рисует menubar иконку (isTemplate=false для яркости на всех экранах)
- `AppDelegate` — меню, таймеры, fetch-функции
- Keychain helpers (save/load/delete)

## Известные ограничения
- OpenAI убрал billing API — баланс недоступен программно, показываем только статус ключа
- Wi-Fi SSID на macOS 14+ требует Location entitlement, fallback через IORegistry
- Claude OAuth — ищет `Claude Code-credentials` в системном Keychain

## История изменений
- 2026-04-12: OpenAI баланс кнопка, календарь 280x200, Claude авто-orgId
- 2026-04-12: Fix dimming на неактивных экранах (isTemplate=false), календарь 310x260, OpenAI→validation
