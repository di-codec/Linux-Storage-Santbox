Чистый путь (он у нас уже срабатывал) — снести и собрать заново одной строкой:

```bash
sudo rm -f /srv/nfs/share/hello.txt
sudo ~/sandbox-teardown.sh && sudo ~/sandbox-setup.sh
```
Проверь, что том смонтирован — две строки:

```bash
df -hT | grep -E 'labvol|nfs-test'
```
Только теперь запускай генератор (без sudo):

```bash
~/generate-messy-data.sh
```
Заодно подчисти лишний файл от nano: rm ~/generate-messy-data.sh.save.
