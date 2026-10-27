# client01: SSH недоступен после клонирования — разбор

## Контекст

- Лаборатория в VirtualBox: `storage01` (Rocky, хранилище) и `client01` (клиент).
- `client01` создан клоном `storage01`.
- После клонирования вручную сменены hostname, machine-id, SSH-ключи.

## Корневая причина

При смене `machine-id` файл `/etc/machine-id` был удалён, а новый не создан.

Это приводило к тому, что D-Bus не стартовал, затем NetworkManager не стартовал, и сеть в VM оставалась неактивной.

## Решение

```bash
sudo rm -f /etc/machine-id
sudo systemd-machine-id-setup
```

После этого перезапустите VM и проверьте сеть:

```bash
ip -4 a
sudo systemctl status dbus-broker NetworkManager
```

## Проверка SSH

```powershell
ssh -p 2223 -o BatchMode=yes p@127.0.0.1 echo ok
```

## Дополнительно

- Для Windows-автоматизации используйте `powershell/snap-watch.ps1`
- Для проверки сетевых интерфейсов см. `scripts/check-step2-client01.sh`
