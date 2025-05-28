**xray脚本自动系统检测搭建节点**  
- 自动识别系统类型（Alpine/Ubuntu/Debian）

## Alpine脚本命令：
#### 查看运行状态：
```
service xray status
```
#### 启动：
```
service xray start
```
#### 重启：
```
service xray restart
```
#### 停止：
```
service xray stop
```
#### 执行命令：
```
apk update && wget https://raw.githubusercontent.com/coco-coc/64m/refs/heads/main/xray.sh -O xray.sh && ash xray.sh
```
#### 完全删除命令：

```
service xray stop
rc-update del xray default
rm -f /etc/init.d/xray
cd /root 
rm -rf ./Xray
```




### **Ubuntu/Dibian脚本命令**
- **查看状态**  
  ```bash
  systemctl status xray
  ```

- **启动/停止/重启**  
#### **启动**
  ```bash
  systemctl start xray
  ```
#### **重启**
  ```bash
  systemctl restart xray
  ```
#### **停止**
  ```bash
  systemctl stop xray
  ```

#### **执行命令**
  ```bash
  apt update && apt install -y wget && wget https://raw.githubusercontent.com/coco-coc/64m/refs/heads/main/xray.sh -O xray.sh && bash xray.sh
  ```
### **完全卸载**
```bash
systemctl stop xray
systemctl disable xray
rm -f /etc/systemd/system/xray.service
systemctl daemon-reload
rm -rf /root/Xray
```
