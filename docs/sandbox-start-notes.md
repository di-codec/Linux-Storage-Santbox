# Sandbox start notes

```bash
sudo rm -f /srv/nfs/share/hello.txt
sudo ~/sandbox-teardown.sh && sudo ~/sandbox-setup.sh
```

Проверь:

```bash
df -hT | grep -E 'labvol|nfs-test'
```

После этого можно запускать генератор данных:

```bash
~/generate-messy-data.sh
```
