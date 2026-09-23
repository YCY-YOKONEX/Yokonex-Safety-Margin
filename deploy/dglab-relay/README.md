# DG-LAB V4 专用中转部署包

本目录将 DG-LAB 官方 `dglab-websocket-server` 固定在提交
`497645525a9ec4e159587d3f2c463d7399ba17e5`，通过 Bun 容器运行 V4 Relay。
Relay 不解析设备控制内容，只在控制端与 DG-LAB App 之间转发 V4 消息。

## 当前服务器

当前实例通过已有 TLS 反向代理发布在：

```text
wss://38.244.4.154.sslip.io:18444/dglab-v4
```

APP 的“我的专用服务器”模式已经预置该地址。

## 非交互部署

将整个目录上传到服务器 `/opt/dglab-relay` 后执行：

```bash
cd /opt/dglab-relay
chmod +x deploy.sh rollback.sh
./deploy.sh
```

脚本会启动容器、把 `nginx-location.conf` 安全加入现有 8444 TLS
`server` 块、运行 `nginx -t`，通过后才重载。配置校验失败会自动恢复备份。
当前 compose 会加入已有的 `proxy-admin_default` Docker 网络；若服务器网络名
不同，需要同步修改 `docker-compose.yml`。

验证外部端点时，普通 HTTPS 请求返回 `426` 是正常的，表示服务正在等待
WebSocket Upgrade。实际配对 URL 由 APP 自动追加随机 `tid`，无需手工填写。

## 更新与回退

- 查看状态：`docker compose ps`
- 查看日志：`docker compose logs --tail=100`
- 停止：`docker compose down`
- 回退时恢复部署前的 Nginx 备份并重载，不会影响 APP 中的官方、局域网或回环模式。

官方源码与协议：<https://github.com/dungeonlab-open/dglab-websocket-server>
（GPL-3.0）。
