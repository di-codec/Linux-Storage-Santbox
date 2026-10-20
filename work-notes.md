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
Install NFS
```bash
sudo dnf install nfs-utils
```
NFS Status
```bash
service nfs status
```
