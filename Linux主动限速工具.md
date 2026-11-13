# Linux 网络限速工具

Linux 双向网络带宽限制脚本，基于 CAKE 实现上传和下载流量整形，支持自动识别出口网卡、交互配置带宽及 systemd 开机自动应用。

## 1. 下载脚本

```sh
curl -fL -o bandwidth-limiter.sh "https://raw.githubusercontent.com/nsloou/my-docs/refs/heads/main/scripts/bandwidth-limiter.sh"
```

## 2. 校验 SHA-256 并运行

```sh
printf '%s  %s\n' \
  '0ca2842a556df0b492ebd670fb7350095a14c08e38bcd6c7fc219c93262d69ce' \
  'bandwidth-limiter.sh' | sha256sum -c - &&
chmod +x bandwidth-limiter.sh &&
./bandwidth-limiter.sh
```

只有 SHA-256 校验通过，才会继续运行脚本。

**注意：** 如果校验失败，请勿执行脚本。运行时需要使用 root 权限。
