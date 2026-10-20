проверка NFS-server:
```bash
rpm -q nfs-utils
```
View the status of the services with the command:
```bash
systemctl status rpcbind
```
Unable/Disable NFS-service:
```bash
systemctl start nfs-lock
systemctl enable nfs-lock
```
