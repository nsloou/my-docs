# Fetch

从 GitHub 私有仓库下载单个文件。使用一个独立的 `fetch.sh`，兼容 Debian 12/13 的 `/bin/sh` 和 Alpine 的 `ash`，不需要额外安装 Bash、jq、Python 或 Git。

## 1. 最小安装 curl

在 VPS 上以 root 执行对应系统的命令，使用已配置且可信的发行版软件源。

### Debian 12 / 13

```sh
apt-get update &&
apt-get install -y --no-install-recommends curl ca-certificates &&
apt-get clean
```

不安装推荐包，只安装指定软件包及必要依赖；`ca-certificates` 用于 HTTPS 证书校验。配套重装系统已包含它，无需卸载或重复准备。最后清理下载的软件包缓存，不删除系统索引、日志，不执行 `autoremove`。

### Alpine

```sh
apk add --no-cache curl
```

curl 的官方依赖包含 libcurl 和 HTTPS 所需的 `ca-certificates-bundle`，无需为普通 HTTPS 下载额外安装完整的证书管理工具。`--no-cache` 不持久保存本次下载的索引缓存；不需要单独运行 `apk update`，也不需要安装 Bash。

以上是发行版官方软件包的最小正常安装方式，不自行编译或手动裁剪它们必需的库，不跳过 HTTPS 证书验证。

## 2. 下载脚本

```sh
curl -fL -o github-file-downloader.sh "https://raw.githubusercontent.com/nsloou/my-docs/refs/heads/main/scripts/github-file-downloader.sh"
```

## 3. 校验并运行

在希望保存下载文件的目录中执行：

```sh
printf '%s  %s\n' \
  '64c4bc33f73c0e51ab48660d2d21dce74cfa5c70c9e42a5b86fa24aed63a3f7b' \
  'github-file-downloader.sh' | sha256sum -c - &&
chmod +x github-file-downloader.sh &&
./github-file-downloader.sh
```

只有 SHA-256 校验通过，才会继续运行脚本。

**注意：** 如果校验失败，请勿执行脚本。

按提示依次输入：

1. 从 Chrome 复制的 GitHub 文件页面网址，例如 `https://github.com/username/aurora/blob/main/目录/文件.sh`。
2. 仅授权目标仓库、Contents 为 Read-only 的 GitHub Token。输入时不显示字符。

收到第一个输入字符后，会立即显示 `已输入 Token，按回车开始下载。`，无需先按回车；此时尚未开始下载。Token 本身、片段和长度均不显示。支持 Backspace 删除和 Ctrl+U 清空，清空后会提示重新粘贴；按回车后才提交下载，留空回车会提示 `Token 不能为空。`。这些提示仅确认输入状态，不代表已验证 Token 的完整性或 GitHub 权限。

支持多级文件夹、中文和空格文件名；分支名支持 `main`、`master` 等不含 `/` 的写法。下载使用原文件名，不覆盖已有同名文件，不自动执行下载内容。

## 下载失败时

回车后直接使用本次下载请求的结果判断，不额外调用认证接口，也不把格式检查当成 Token 有效性证明。

- `401`：提示 GitHub 认证失败，Token 可能输入有误、已过期或已撤销。
- `403`：提示可能存在权限、访问策略或频率限制；不直接归因于 Token 输入错误。
- `404`：提示检查文件网址、分支和仓库授权；不武断认定文件不存在。
- 网络、DNS、TLS、超时、传输中断和本地写入失败分别提示原因。

只有 curl 完整传输成功且最终返回 `200`，才保存为目标文件。输错 Token 或下载失败时，删除本次临时文件，不保留错误响应、残缺目标文件或 Token 缓存，不覆盖原有文件。如果文件系统故障导致临时文件无法删除，会明确报错并给出路径，不声称已经清理完成。

## 安全与清理

- Token 通过标准输入传给 curl，不放入 curl 的命令行参数或导出的环境变量，也不主动保存到文件。
- 强制 HTTPS，保留证书验证，限制连接和下载等待时间。
- 下载到当前目录的私有临时文件，成功后才发布为目标文件；最终文件权限为 `600`。
- 正常成功、下载失败或 Ctrl+C 退出时清理临时文件，并恢复终端回显。强制 `kill -9` 或断电不能触发清理，可能留下 `.fetch.*` 临时文件。
- 下载成功只代表传输完成，不代表脚本本身已经通过安全审查；执行前仍应核对独立可信的 SHA-256。
