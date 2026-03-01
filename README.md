# Windows School Lock

Система защиты Windows 11 от несанкционированных действий ученика.
Работает через ACL, групповые политики и планировщик задач.

---

## Окружение

| Параметр | Значение |
|---|---|
| ОС | Windows 11 в Docker-контейнере `dockurr/windows` |
| Пользователь | `user` (WIN-EAVIF799CG9\user) |
| Администратор | `Администратор` (SID `*-500`) |
| Пароль | `tutoradmin` |
| Shared папка | `./shared:/shared` → монтируется как `Z:\` |
| Основной скрипт | `C:\Windows\System32\svchost_cfg\svchost_cfg.ps1` |
| AHK скрипт | `C:\Windows\System32\svchost_cfg\hotkeys.ahk` |

---

## Файлы проекта

```
Z:\
├── svchost_cfg.ps1       # Основной скрипт Lock/Unlock
└── Install-SchoolLock.ps1 # Установщик (запустить один раз)
```

---

## Установка (один раз)

1. Скопируй оба файла в `./shared/` на хосте (Linux)
2. Внутри Windows открой PowerShell **от имени Администратора**
3. Выполни:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
Z:\Install-SchoolLock.ps1
```

Установщик автоматически:
- Создаст скрытую системную папку `C:\Windows\System32\svchost_cfg\`
- Скопирует скрипт
- Скачает и установит AutoHotkey
- Создаст задачи в планировщике
- Добавит AutoHotkey в автозапуск
- Применит Lock сразу

---

## Использование

### Горячие клавиши
| Клавиши | Действие |
|---|---|
| `Win + F1` | Включить защиту (Lock) |
| `Win + F2` | Снять защиту (Unlock) |

Работают тихо — без окон и консоли.

### Вручную через PowerShell (от Администратора)
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

# Включить защиту
& "C:\Windows\System32\svchost_cfg\svchost_cfg.ps1" -Action Lock -AdminPassword "tutoradmin"

# Снять защиту
& "C:\Windows\System32\svchost_cfg\svchost_cfg.ps1" -Action Unlock -AdminPassword "tutoradmin"
```

### Автоматически
Lock применяется автоматически при каждом входе в систему
через задачу планировщика `\Microsoft\Windows\SystemCache\MicrosoftWindowsServiceHost`.

---

## Что блокируется

| Защита | Метод |
|---|---|
| Рабочий стол — создание/удаление/перемещение | ACL Deny Write/Delete на `user` |
| Смена обоев | Реестр `HKU\<SID>` Policies |
| Диспетчер задач | Реестр `DisableTaskMgr` |
| Regedit | Реестр `DisableRegistryTools` |
| Панель управления / Параметры | Реестр `NoControlPanel` |
| CMD / PowerShell | Реестр `DisableCMD` + ACL Deny |
| Опасные системные утилиты | ACL Deny на .exe в System32 |
| Установка программ (.exe/.msi) | `DisableMSI` + `DisableUserInstalls` |
| Microsoft Store | `DisableStoreApps` |
| Запись в Program Files | ACL Deny на папки |
| Запуск из Downloads/Temp | SRP (Software Restriction Policy) |
| Запись на USB | `StorageDevicePolicies\WriteProtect` |

---

## Задачи планировщика

| Задача | Путь | Триггер |
|---|---|---|
| `MicrosoftWindowsServiceHost` | `\Microsoft\Windows\SystemCache\` | При каждом логоне |
| `SchoolLock_LOCK` | `\Microsoft\Windows\SystemCache\` | Win+F1 (вручную) |
| `SchoolLock_UNLOCK` | `\Microsoft\Windows\SystemCache\` | Win+F2 (вручную) |

---

## Важные особенности (для разработки)

> Эти особенности критичны — несоблюдение ломает скрипт или систему.

- **Русская Windows** — `BUILTIN\Users` не работает, только SID `S-1-5-32-545`
- **ACL на конкретного пользователя** — Deny на группу блокирует Explorer и скрывает иконки рабочего стола
- **Deny только Write/Delete** — добавление `Modify` в Deny блокирует отображение иконок
- **Реестр через `HKEY_USERS\<SID>`** — не через `HKCU` и не через `reg load`
- **Только английский в строках** — кириллица в `Write-Host` и строках ломает парсер PowerShell
- **Перед запуском** всегда нужно: `Set-ExecutionPolicy Bypass -Scope Process -Force`
- **Запуск только от Администратора** (`#Requires -RunAsAdministrator`)

---

## Решённые проблемы

| Проблема | Решение |
|---|---|
| `BUILTIN\Users` не резолвится | Использовать SID `S-1-5-32-545` и `.Translate()` |
| `reg load` не работает | Использовать `HKEY_USERS\<SID>` напрямую |
| Deny на группу → Explorer не открывает Desktop | Deny только на конкретного `user` по SID |
| `Modify` в Deny → иконки не отображаются | Deny только `Write,Delete,CreateFiles,CreateDirectories` |
| Кириллица → парсер падает | Только ASCII в строках PowerShell |
| Реестр заблокирован после Lock | Разблокировать через .NET: `[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(...)` |
| GUI не появляется при запуске от SYSTEM | Пароль в аргументах задачи, `-NonInteractive -WindowStyle Hidden` |

---

## Экстренное снятие блокировки

Если скрипт недоступен (заблокирована папка Desktop):

```powershell
# Снять блокировку реестра
$regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    "Software\Microsoft\Windows\CurrentVersion\Policies\System", $true)
if ($regKey) { $regKey.DeleteValue("DisableRegistryTools", $false); $regKey.Close() }

# Снять ACL с рабочего стола
$acl = Get-Acl "C:\Users\user\Desktop"
$acl.SetAccessRuleProtection($false, $true)
$acl.Access | Where-Object { $_.AccessControlType -eq "Deny" } |
    ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
Set-Acl "C:\Users\user\Desktop" $acl
```
