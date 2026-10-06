# codespace-remote-gui-browser

在 GitHub Codespaces 上跑一个**真实位于海外的 Chrome**，通过 VNC 从本机访问。

免费额度内可完成注册类流程。**已解决无 GPU 云环境下 Chrome 反复 SIGTRAP 崩溃的问题**——这是网上现有教程都没覆盖、且极易被误诊为"网络故障"的坑。

---

## 为什么不用 VPN

地区门禁看的是**浏览器环境指纹**，不只是出口 IP：时区、语言、字体、TLS 握手特征都参与判断。纯代理只改 IP、其余全留本机 → 被识别为非本地用户。

云浏览器的价值在于**浏览器进程真的跑在目标地区**，IP 与环境自洽。这是挂代理做不到的。

---

## 快速开始

```bash
# 前置：gh 已登录，且 token 有 codespace scope
gh auth refresh -h github.com -s codespace

# 仓库需已有 main 分支（空仓库要先推一个 commit）
./scripts/setup-remote-gui.sh --repo <owner>/<repo> --region WestUs3
```

脚本会依次完成：建 Codespace → 拉 Chrome 容器 → **注入软件渲染修复** → 装 nginx 终止 TLS → 建端口转发 → 验证出口 IP。

结束后浏览器打开 `https://127.0.0.1:8443`，自签证书点「继续访问」。

收尾：

```bash
./scripts/cleanup.sh <codespace-name> <owner/repo>
```

**完整踩坑清单见 [SKILL.md](SKILL.md)** —— 12 个环境坑，每个都附了根因和判据。

---

## 核心坑：Zink 导致 SIGTRAP

这是本项目最有价值的部分，也是最容易被浪费几小时的地方。

**症状**：页面打开 → `Error code: SIGTRAP` → 新标签全崩 → `Kasm encountered an error` → 桌面黑屏、Chrome 不再自动拉起。

**真因**：`kasmweb/chrome` 默认走 **Zink**（Vulkan 转 OpenGL）加速，无 GPU 的云 VM 上加载失败：

```
MESA: error: ZINK: failed to choose pdev
failed to load driver: zink
```

→ Chrome 渲染进程崩溃 → SIGTRAP。

**SIGTRAP 长得很像网络错误，但不是。** 判据（三条都过 = 不是网络问题）：

```bash
docker exec cloud-browser sh -c 'free -m | head -3'          # 内存充足
docker exec cloud-browser sh -c 'curl -s -o /dev/null -w "%{http_code}" https://example.com'  # 网络通
# 真因在这里 —— 抓 Chrome 启动 stderr
docker exec -u kasm-user -e DISPLAY=:1 -e HOME=/home/kasm-user \
  cloud-browser timeout 25 /usr/bin/google-chrome --start-maximized 2>&1 | grep -i zink
```

**修复**：强制 SwiftShader 软件渲染。容器内 `/usr/bin/google-chrome` 是 root 不可写、`custom_startup.sh` 是设备文件，**所有官方注入点都走不通**——正解是在可写的 HOME 下建自己的启动脚本（见 SKILL.md 第 4 步）。

> `CHROME_ARGS` / `KASM_EXTRA_CHROME_ARGS` 环境变量在 1.15 版**均不生效**，别浪费时间试。

---

## 其他关键坑

| 现象 | 真因 | 一句话解法 |
|---|---|---|
| 白屏 / 一直 connecting | KasmVNC 拒明文 WS（`non-SSL connection disallowed`） | 加 nginx 反代终止 TLS |
| 反代后 502 | `proxy_pass` 写成了 `http://` | KasmVNC 只服务 HTTPS，必须 `https://` |
| `HTTP 403 Must have admin rights` | token 缺 `codespace` scope | `gh auth refresh -s codespace` |
| `The value of the GITHUB_TOKEN...` | 环境变量优先级高于 keyring | 先 `unset GITHUB_TOKEN` |
| `no such machine` | 机器类型名不存在 | 先用错误信息里的 `Available machines` 列表 |
| `The 'ref' provided was invalid` | 空仓库无 main 分支 | 先推一个 commit |
| `bind: permission denied` | 本机要绑 443 | 参数是 `remote:local`，写 `443:8443` |
| `Address in use` (98) | 宿主 nginx 占 443 | `sudo nginx -s stop` |
| `XDG_RUNTIME_DIR not set` | 环境变量缺失 | 启动脚本里 export |

---

## 成本

GitHub 个人账号免费 **120 core-hours/月**（2 核 = 60 小时运行时间）+ 15 GB 存储。注册类流程几十分钟即可完成，**额度绰绰有余**。超出后 2 核 $0.18/小时。

来源：<https://github.com/features/codespaces> · <https://docs.github.com/billing/managing-billing-for-github-codespaces>

---

## ⚠️ 合规与风险

**绕过地区门禁通常违反目标服务的 ToS。** 使用前请知悉：

- 账号可能被主动复核、限制或删除，通常**无申诉通道**
- 社区案例：开通 2–3 天后被打回；IP 跳变被「锁定」且工单 403
- 社区案例：用户用它运营其他平台账号，被**连带封禁**
- 建议**不要**接入真实邮箱、通讯录、主账号

本仓库只提供技术方法，**不对任何具体服务的使用后果负责**。请自行评估风险。

## 已知限制

- **KasmVNC 坐标映射有偏移**，远程桌面点击可能落不准 → 用 Tab + Enter，或用左侧「按键」面板
- 容器重启会重置桌面会话
- 复杂表单建议改用 CDP / headless 方案绕开图形栈

## License

MIT
