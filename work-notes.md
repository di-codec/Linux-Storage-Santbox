проверка NFS-server:
```bash
rpm -q nfs-utils
```
View the status of the services with the command:
```bash
systemctl status rpcbind
```
If the `nfs-utils` package is installed:
```bash
sudo dnf uninstall nfs-utils
```
