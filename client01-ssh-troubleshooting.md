# client01: SSH недоступен после клонирования — разбор

## Контекст

- Лаборатория в VirtualBox: `storage01` (Rocky, хранилище) и `client01` (клиент).
- `client01` создан клоном `storage01`. После клонирования вручную сменены hostname, machine-id, SSH-ключи.
- Задача: запустить `snap-watch.ps1`, который заходит в обе VM по SSH и делает снапшоты при изменении конфигов.

## Корневая причина

При смене machine-id файл `/etc/machine-id` был удалён, а новый не создан.

```
нет /etc/machine-id → D-Bus не стартует → NetworkManager не стартует
→ у интерфейсов нет IP → VirtualBox NAT некуда доставить соединение → SSH снаружи недоступен
```

---

## Шаг 1. Скрипт не находится

**Ошибка**
```
The argument 'C:\Users\covuk\snap-watch\snap-watch.ps1' to the -File parameter does not exist.
```

**Что это:** путь в команде не совпадает с местом, где лежит файл. Скрипт лежит в папке проекта, а не в `C:\Users\covuk\snap-watch\`.

**Решение** (из папки, где лежит скрипт)
```powershell
powershell -ExecutionPolicy Bypass -File ".\snap-watch.ps1"
```
`.\` — текущая папка. Для Task Scheduler нужен полный путь в кавычках (в пути есть пробелы).

**После починки**
```
PS C:\Users\covuk\desktop\projects\Linux Sandbox Storage>
```
Пустой вывод — норма: скрипт пишет только в лог.

---

## Шаг 2. Где смотреть результат

**Что это:** скрипт ничего не выводит на экран. Всё пишется в `snap-watch.log` в папке `$WorkDir` (`C:\Users\covuk\snap-watch\`), а не рядом со скриптом.

**Команда**
```powershell
Get-Content "$env:USERPROFILE\snap-watch\snap-watch.log"
# в реальном времени:
Get-Content "$env:USERPROFILE\snap-watch\snap-watch.log" -Wait -Tail 20
```

**Что было в логе**
```
2026-10-23 05:08:36  storage01 not running - skipped
2026-10-23 05:08:36  ERROR client01: ssh failed (exit 255): root@127.0.0.1: Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password).
2026-10-23 05:08:36  baseline saved (0 items)
```
`baseline saved (0 items)` — ни одна VM не прочитана. Безвредно: при следующем запуске baseline создаётся заново.

---

## Шаг 3. `storage01 not running - skipped`

**Что это:** VirtualBox ответил, что VM с таким именем не запущена. Либо машина выключена, либо имя в CONFIG не совпадает с именем в VirtualBox.

**Проверка**
```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" list runningvms
```

**Ожидаемый вывод**
```
"storage01" {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}
"client01"  {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}
```
Имена в `$VMs` скрипта должны совпадать с этими буква в букву.

---

## Шаг 4. `Permission denied (publickey...)` для root

**Ошибка**
```
root@127.0.0.1: Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password).
```

**Что это:** скрипт заходит с `BatchMode=yes` — только по ключу, без пароля. Ключа Windows у root на client01 нет. Root скрипту и не нужен — для этого есть пользователь `p` + sudo.

**Проверка** (на client01)
```bash
sudo cat /root/.ssh/authorized_keys
```
```
cat: /root/.ssh/authorized_keys: No such file or directory
```

**Решение:** в CONFIG заменить `root@127.0.0.1` на `p@127.0.0.1` и добавить ключ Windows пользователю `p` (пароль спросят 1 раз):
```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh -p 2223 p@127.0.0.1 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```
Если файла `id_ed25519.pub` нет — сначала `ssh-keygen -t ed25519`.

**После починки**
```powershell
ssh -p 2223 -o BatchMode=yes p@127.0.0.1 echo ok
```
```
ok
```

---

## Шаг 5. `Connection refused`

**Ошибка**
```
ssh: connect to host 127.0.0.1 port 2223: Connection refused
```

**Что это:** на Windows никто не слушает порт 2223. VM ещё грузится или проброс порта не активен.

**Решение:** дождаться загрузки VM и повторить. Если не проходит — проверить правило проброса (шаг 6).

---

## Шаг 6. `kex_exchange_identification: Connection reset`

**Ошибка**
```
kex_exchange_identification: read: Connection reset
Connection reset by 127.0.0.1 port 2223
```

**Что это:** VirtualBox принял соединение, передал внутрь VM, а там его сбросили. Проброс есть, а SSH на том конце недоступен.

**Проверка 1: работает ли sshd** (на client01)
```bash
sudo systemctl status sshd
sudo ss -tlnp | grep ssh
```
```
Active: active (running)
LISTEN 0  128  0.0.0.0:22  0.0.0.0:*  users:(("sshd",pid=761,fd=7))
```
sshd в порядке, слушает 22 → проблема на пути между Windows и sshd.

**Проверка 2: правило проброса** — client01 → Settings → Network → NAT → Advanced → Port Forwarding:

| Host IP | Host Port | Guest IP | Guest Port |
|---|---|---|---|
| пусто / 127.0.0.1 | 2223 | **пусто** | **22** |

Guest Port = порт из `ss`. У storage01 Host Port 2223 повторяться не должен (клон копирует правила NAT).

---

## Шаг 7. У VM нет IP-адреса

**Ошибка**
```bash
ip -4 a
```
```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 ...
    inet 127.0.0.1/8 scope host lo
```

**Что это:** есть только loopback. NAT-интерфейс без адреса `10.0.2.15` → VirtualBox некуда доставить соединение → `Connection reset`.

**Решение:** искать, почему не поднялась сеть (шаг 8).

---

## Шаг 8. `DBUS_ERROR`

**Ошибка**
```bash
sudo firewall-cmd --list-all
```
```
Error: DBUS_ERROR: Failed to connect to socket /run/dbus/system_bus_socket: Connection refused
```

**Что это:** не работает D-Bus — системная шина, через которую службы общаются между собой. Без неё не работают NetworkManager (поднимает сеть) и firewalld. Цепочка: D-Bus упал → NetworkManager не запустился → нет IP → нет SSH.

**Проверка**
```bash
sudo systemctl status dbus-broker NetworkManager
```
Обе службы будут `failed` / `inactive`. Причина — шаг 9.

---

## Шаг 9. Нет `/etc/machine-id` (корневая причина)

**Ошибка**
```bash
cat /etc/machine-id
```
```
cat: /etc/machine-id: No such file or directory
```

**Что это:** D-Bus читает machine-id при старте. Нет файла — D-Bus не стартует. Файл пропал при ручной смене ID на клоне.

**Решение:** создать ID штатным инструментом, не руками.
```bash
sudo rm -f /etc/machine-id
sudo systemd-machine-id-setup
```
```
Initializing machine ID from random generator.
```

**Проверка формата**
```bash
cat /etc/machine-id
```
```
3f9c2a1be0d54c6aa7b81e2f90d3c4e5
```
Ровно 32 символа `0-9a-f`, 1 строка.

**Не нужно:** `ln -s /etc/machine-id /var/lib/dbus/machine-id`. На Rocky папки `/var/lib/dbus/` нет, dbus-broker читает только `/etc/machine-id`. Ошибку `ln: failed to create symbolic link ... No such file or directory` игнорировать.

---

## Шаг 10. Перезагрузка и проверка

```bash
sudo reboot
```

**После загрузки**
```bash
ip -4 a
```
```
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    inet 10.0.2.15/24 brd 10.0.2.255 scope global dynamic noprefixroute enp0s3
```

```bash
sudo systemctl status dbus-broker NetworkManager
```
```
Active: active (running)
...
Active: active (running)
```

**С Windows**
```powershell
ssh -p 2223 -o BatchMode=yes p@127.0.0.1 echo ok
```
```
ok
```

---

## Шаг 11. Повторный запуск скрипта

```powershell
powershell -ExecutionPolicy Bypass -File ".\snap-watch.ps1"
Get-Content "$env:USERPROFILE\snap-watch\snap-watch.log" -Tail 5
```

**Ожидаемо**
```
2026-10-23 15:40:02  baseline saved (N items)
```

**Если вместо этого**
```
ERROR client01: sudo needs a password
```
**Что это:** скрипту нужен sudo без пароля для чтения `/etc/target`, сетевых конфигов и т.п.

**Решение** (на каждой VM)
```bash
sudo visudo -f /etc/sudoers.d/snapwatch
```
```
p ALL=(root) NOPASSWD: /usr/bin/find, /usr/bin/stat, /usr/bin/true
```
Минус: `find` от root фактически даёт `p` root-доступ. Для лаборатории допустимо, для продакшена — нет.

---

## Выводы

- **Machine-id на клоне меняется только через `systemd-machine-id-setup`.** Ручное удаление/правка ломает D-Bus, а с ним сеть.
- **Клон копирует правила NAT.** Host Port у каждой VM должен быть свой.
- **`Connection reset` при работающем sshd** — проблема на пути: проброс, IP интерфейса, firewall.
- **После починки — ручной снапшот** (`manual_client01-fixed`): первое рабочее состояние клона.
