---
name: "ZMK 蓝牙连不上主机排查链"
description: "Totem/ZMK 键盘蓝牙无法连接 Linux 主机的完整诊断流程:从固件误区到 BlueZ Pairable/agent 根因,含串口日志诊断构建方法。"
---

# ZMK 蓝牙连不上主机排查链

> 适用:ZMK 固件键盘(Totem / XIAO BLE 等)蓝牙无法连接 Linux 主机。
> 本文是一次真实排查的提炼,按从易到难、从键盘到主机的顺序排查。

## 何时用

症状:键盘 USB 能打字,蓝牙扫不到 / 扫到连不上 / 连上立刻断。
已排除:左右分体断连(只插左半边 USB,按右半边键也能打字 → 分体正常)。

## 决策树(按顺序问)

```
USB 能打字吗?
├─ 否 → 固件/kscan 层问题,重刷 totem_left/right,不在本文范围
└─ 是 → 拔掉 USB,键盘还活着吗?(Peahen 广播 ts 新鲜度 / 按任意键)
   ├─ 秒死且按键救不活 → 先按 §场景5 查睡死(带载判决),再查供电(场景4 开关/JST)
   └─ 活着 → 问题在蓝牙层,继续 ↓

左右分体连上了吗?(只插左 USB,按右半边键能打字?)
├─ 否 → split 蓝牙断连,刷 settings_reset + 重刷两半固件,见 §固件误区
└─ 是 → 锁定「左半边(central)→ 主机」这段,继续 ↓

刷 settings_reset 还是不行?
├─ 是 → 你可能踩了 §固件误区(settings_reset 不是键盘固件,必须刷回正常固件)
└─ 已刷回正常固件仍不行 → 开串口日志,见 §诊断构建

串口日志显示什么?
├─ "pairing failed (peer reason 0xc)" → 主机拒绝了配对,见 §根因1+2
├─ "Security failed ... err 1"         → 同上(SMP Pairing Not Supported)
├─ 完全没有 advertising 行             → 中心没在广播,固件/硬件层问题
└─ Connected 紧跟 Disconnected         → 连上即断,看 §根因2(agent)
```

## 固件误区(settings_reset 不是键盘固件)

`settings_reset` 是**一次性清空工具**,不是正常固件。它启动时清掉整个设置分区(蓝牙 bond / split 配对 / profile),**同时把蓝牙彻底关掉**(`CONFIG_ZMK_BLE=n`),防止清空时两半自动重连。

> ZMK 官方原话:"You will not be able to pair your keyboard or see it in any Bluetooth device lists **until you have flashed the normal firmware again**."

**正确流程(4 次刷写)**:

1. 左半边 → `settings_reset-...uf2`(清空)
2. 右半边 → `settings_reset-...uf2`(清空)
3. 左半边 → `totem_left-...uf2`(**刷回正常固件,这步最容易漏**)
4. 右半边 → `totem_right-...uf2`(**刷回正常固件**)

漏了第 3、4 步,键盘就处于「蓝牙关闭」状态——主机当然连不上。刷普通固件**不会**清掉配对(ZMK 设计如此),所以日常改 keymap 不用重新配对。

## 诊断构建(开 USB 串口日志)

当固件层正常、蓝牙层出问题时,最准的诊断是读左半边(central)的 USB 串口日志。

### 改两个文件(临时)

`config/boards/shields/totem/totem_left.conf`(原本是空文件):

```conf
CONFIG_ZMK_USB_LOGGING=y
CONFIG_LOG_DEFAULT_LEVEL=3
CONFIG_ZMK_STUDIO=n   # 临时关 Studio,避开两个 CDC snippet 共存冲突(zmk#3031)
```

`build.yaml`(左半边 snippet 临时换掉):

```yaml
  - board: seeeduino_xiao_ble
    shield: totem_left
    snippet: zmk-usb-logging   # DIAGNOSTIC: 原来是 studio-rpc-usb-uart
```

> `zmk-usb-logging` snippet(v0.3 起存在)会自动建 CDC-ACM UART 节点并设
> `CONFIG_ZMK_USB_LOGGING=y`。左半边是 central,同时管「主机 BLE」和「split BLE」,
> 它的日志最全。右半边不用动。

### 构建 + 刷 + 读日志

```bash
# 推送到 GH Actions 构建(fork 仓库记得加 --repo <你的fork>)
git push origin diagnostic/usb-logging
gh run list --repo <你的fork> --branch diagnostic/usb-logging
gh run download <run-id> --repo <你的fork> --dir /tmp/totem-diag

# 刷左半边:双击 reset 进 U 盘,拖入 totem_left-...uf2
# 读串口(nix run 免安装 tio):
nix run nixpkgs#tio -- /dev/ttyACM0    # 找 VID=1d50 的那个 ttyACM
```

> **抓启动日志的坑**:按 reset 时 USB 设备会断开重连,单个 `cat` 拿着旧句柄读不到。
> 要用自动重连循环:设备消失就等、出现就重新 `cat`。或者刷完再按一次 reset + 立即配对,
> 让启动 + 配对事件都在捕获窗口里。

### 日志关键字

| 日志行 | 含义 |
|---|---|
| `auth_pairing_accept: role 1, open? yes` | 中心接受了配对请求(到这步为止正常) |
| `pairing failed (peer reason 0xc)` | **主机**拒绝了配对(0xc=Pairing Not Supported) |
| `Security failed: <MAC> level 1 err 1` | SMP 安全握手失败 |
| `disconnected (reason 0x13)` | reason 0x13=Remote User Terminated(主机主动断) |
| `security_changed: ... level 2` | 加密成功(level 2)——配对成功了 |
| 完全没有 `advertising` 行 | 中心没在广播 |

### 还原

诊断完务必还原:`totem_left.conf` 清空(0 字节)、`build.yaml` snippet 改回
`studio-rpc-usb-uart`。master 分支 `git checkout -- .` 即可。诊断分支删除:
`git push origin --delete diagnostic/usb-logging`。

## 根因 1:BlueZ 默认 Pairable: no

**日志特征**:`pairing failed (peer reason 0xc)` + `Security failed ... err 1`。
**主机端确认**:`bluetoothctl show` 显示 `Pairable: no`。

BlueZ 5.x 在很多发行版默认 `Pairable: no`,根本不接受新配对。键盘发配对请求、
主机 SMP 直接回 reason 0xc。这跟键盘存的旧 bond 无关,所以刷 settings_reset 没用。

**修复**:

```bash
bluetoothctl pairable on
```

## 根因 2:没有蓝牙 agent(passkey 确认无人应答)

**症状**:开了 Pairable 后「连上一下就断开」。
**主机端确认**:`journalctl -u bluetooth` 刷 `No agent available for request type 2`

+ `device_confirm_passkey: Operation not permitted`。

BlueZ 配对到需要确认 passkey 那一步(`request type 2` = CONFIRM_PASSKEY),必须有
一个"蓝牙 agent"注册来弹确认框 / 自动应答。没有 agent → BlueZ 自动拒绝 → 断开。
桌面环境通常由 GNOME/KDE 蓝牙组件提供 agent;niri + Caelestia 这类自组 WM 没有。

**临时修复**(CLI 当 agent):

```bash
bluetoothctl
[bluetoothctl] agent on
[bluetoothctl] default-agent
[bluetoothctl] pair <键盘MAC>
[bluetoothctl] trust <键盘MAC>
[bluetoothctl] connect <键盘MAC>
```

**永久修复**(NixOS,无桌面 agent 的 WM):

用 `bluez-tools` 的 `bt-agent`(无 UI 纯 agent)当常驻 systemd user service:

`profiles/hardware/bluetooth.nix`:

```nix
{ pkgs, ... }:
{
  hardware.bluetooth = { enable = true; powerOnBoot = true; };
  environment.systemPackages = [ pkgs.bluez-tools ];
}
```

`hosts/<host>/home.nix`:

```nix
systemd.user.services.bt-agent = {
  Unit = {
    Description = "BlueZ pairing agent (headless, bt-agent)";
    PartOf = [ "graphical-session.target" ];
    After = [ "graphical-session.target" ];
  };
  Service = {
    ExecStart = "${pkgs.bluez-tools}/bin/bt-agent --capability=NoInputNoOutput";
    Restart = "on-failure";
  };
  Install.WantedBy = [ "graphical-session.target" ];
};
```

> `--capability=NoInputNoOutput` 走 Just Works 静默配对(无确认弹窗)。ZMK 键盘
> 本身就是 open/Just Works 模式,最顺。日后若要给新设备强制 numeric comparison
> 确认,换 `--capability=DisplayYesNo` 或用 blueman-applet(带 GUI 确认弹窗)。

### 为什么不用 blueman-applet

blueman-applet 当 agent 能用,但它的 `StatusIcon` 插件会拉起 `blueman-tray`,
被 Caelestia(Quickshell)的 StatusNotifierWatcher 收留成侧边栏**第二个**蓝牙图标,
与 Caelestia 原生蓝牙控件重复。`gsettings org.blueman.general plugin-list=['!StatusIcon']`
**关不掉**——`PersistentPluginManager.__load_plugin` 主加载路径不在 `disable_plugin`
上做跳过(只用于冲突解决),StatusIcon 照常加载出图标。blueman 要么整个留(带图标),
要么整个换掉,没有"留 agent 去图标"的中间态。bt-agent 无 UI 是干净解。

## 验证清单

+ [ ] `bluetoothctl show` → `Pairable: yes`
+ [ ] `bluetoothctl info <键盘MAC>` → `Paired/Bonded/Trusted/Connected: yes`
+ [ ] `journalctl -u bluetooth` → 无 `No agent available`
+ [ ] 拔掉 USB,蓝牙能打字
+ [ ] 侧边栏只有一个蓝牙图标(Caelestia 原生)

## 时间线参考(本次实际排查)

1. 初始:蓝牙扫不到 → 怀疑 bond 错乱 → 刷 settings_reset → 还是连不上
2. 发现 settings_reset 误区 → 刷回正常固件 → 仍连不上
3. 开 USB 串口日志(诊断构建) → 看到 `pairing failed peer reason 0xc`
4. 定位根因 1:BlueZ `Pairable: no` → `pairable on`
5. 配对能启动但「连上即断」 → 看到 `No agent available for request type 2`
6. 定位根因 2:无桌面 agent → `bluetoothctl agent on` 手动配对成功
7. 永久化:blueman-applet → 重复图标 → 换 bt-agent 无 UI(改 nixos-config)

## 相关文件(本仓)

+ `config/west.yml` — ZMK 版本钉在 `v0.3`(注:`v0.3` 与 `v0.3.0` 是同一 commit)
+ `build.yaml` — 构建矩阵,含 `settings_reset` shield
+ `config/boards/shields/totem/totem.keymap` — ADJ 层有 BT_CLR/BT_NXT/BT_PRV/OUT_TOG
+ `config/totem.conf` — `CONFIG_ZMK_USB_LOGGING=n`(诊断时临时改 left.conf 覆盖)

## 相关文件(nixos-config 仓)

+ `profiles/hardware/bluetooth.nix` — `bluez-tools` + bt-agent 说明
+ `hosts/forge-os/home.nix` — `bt-agent` systemd user service

---

## 场景 2:刷固件后「连得上但打字没反应」

**症状**:BlueZ 显示 Connected/Bonded,键盘自身广播正常(层/电量遥测都在走),
但主机没有输入设备(`libinput list-devices` 查不到键盘),打字零响应。

**根因**:新固件改了 GATT 表(本次:开 `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_PROXY`
新增 BAS 服务),BlueZ 的已配对 service cache 失效,HID hog 注册不上。
`disconnect`/`connect` 重连**不能**修。

**修法(双向清 bond 重配)**:

1. 主机:`bluetoothctl remove <MAC>`
2. 键盘:ADJ 层按 `BT_CLR`(清当前 profile 的键盘侧 bond)
3. 重新配对(参照场景 1 的验证清单)

**预防**:凡是改了 GATT 服务集的 Kconfig(BAS/HID/自定义 service),刷机后直接走一遍重配,
不用等用户发现。

## 场景 3:Kconfig 改动疑似没生效 → 用 CI 产物 md5 实锤

`menuconfig`/`if` 块 gate 住的符号(如 `ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_PROXY`
被 `..._FETCHING` gate),只写子符号 = 静默空操作,构建不报错。
验证法:下载相邻两次 CI 的 uf2 比 md5——**md5 相同 = 配置没进构建**,去查父开关。

## 场景 5:一拔线就死(睡死,不是断电)——睡眠配置 + v0.3 唤醒失败合谋

2026-08-23 实战:Totem 插线一切正常,拔线瞬间广播冻结、蓝牙断、按键全无;
体感「蓝牙突然坏了,必须插线」,极易误诊为电池/供电硬件问题。

### 机制(两层合谋)

1. activity.c:空闲计时器插着 USB 也照跑,System OFF 仅被 `!is_usb_power_present()`
   压住 → 长时间插线挂机后空闲早已超时,拔线瞬间闸门打开 → 立即 System OFF
2. v0.3 的 System OFF 按键唤醒在这套板(XIAO BLE)上不工作 → 睡死=假砖,
   插回 USB 才能复活。蓝牙层完全无辜(bond/agent/缓存都可能是好的)

### 判决链(实测有效,按序)

1. Peahen 广播 ts 新鲜度 = 键盘生死探针(status.json)。注意:睡死也会冻结,
   广播冻结 ≠ 断电
2. 万用表在路测量排除供电:电池 4V 直达 XIAO 模块脚 + 3V3 主轨有电
   —— ⚠️ System OFF 下 3V3 依然有电,有电 ≠ 在运行
3. 带载判决(终审):表笔钉 3V3,拔线后按住键 5s:
   + 轨稳如泰山 + 板死寂 → 睡死实锤 → 关 CONFIG_ZMK_SLEEP 重刷
   + 轨下坠/归零 → 电池带载塌陷,才是真·电池问题(空载 4V 会骗人)
4. 开关(JST/MSK12C02)正常 + 模块脚 4V + 轨稳 → 固件,不要再往硬件想

### 修法

`config/totem.conf` 注释掉 CONFIG_ZMK_SLEEP / CONFIG_ZMK_IDLE_SLEEP_TIMEOUT,
重刷两半(同配置刷写不清 bond,不用重配对)。代价:闲置静息耗电恢复
(约 30μA vs 0),长时间存放建议用板载开关断电。升级 ZMK 验证唤醒可靠后
可恢复睡眠。

### 教训
+ 「拔线即死」先做带载判决再谈换件:本次先差点换 XIAO,又差点换电芯
+ 场景 2 的 GATT 缓存问题可能同时叠加(插线 Connected 但无 HID)——
  本例先修缓存后修睡眠,两个都是真的,修完一个别急着结案
+ 电量 % 乱跳不一定是坏电池:插线读数本来就是假的(场景4),
  别拿它当电池健康证据
+ 同步拔线实验:先起后台监控再让用户拔线保持到回答完,时序才不会糊

## 场景 4:电量显示十分有九分不准(显示偏高+没电早)→ 串口 mV 曲线定案

2026-08 实战:Totem 左半「插着线充一会灯就灭」,仪表盘长期 92%,实际用半小时就断电。

### 先记住硬件事实(XIAO BLE / Totem)

+ ZMK 电量 = 电压估讧:`lithium_ion_mv_to_pct()` 一条直线(3450→1%,4200→100%),
  **插线充电时任何 % 都是假的**(充电电流抬压可虚高 +50 点)
+ 充电时采样后 % 会缓存广播;空闲 30s 停采后缓存值永久外发 → 「92%」其实是充电瞬间的假象
+ **板载电源开关 OFF 时电池回路断开,插线不充电**——充电时必须拨到 ON(本次真正的病根)

### 诊断链(全零操作采集,不需要用户打字)

1. **固件**(分支 `diagnostic/battery`,可直接复用):左半 snippet 换 `zmk-usb-logging`,
   `totem_left.conf` 加 `CONFIG_ZMK_USB_LOGGING=y` + `CONFIG_ZMK_STUDIO=n`(CDC 冲突 zmk#3031)
   + `CONFIG_ZMK_IDLE_TIMEOUT=86400000`(否则空闲 30s 停采)+ `CONFIG_ZMK_BATTERY_REPORT_INTERVAL=30`
   ⚠️ 不要写 `CONFIG_ZMK_LOG_LEVEL`——无 prompt 符号,Kconfig 直接拒构建(默认已是 4)
2. **刷机**:值守脚本盯 XIAO-SENSE 盘出现即 cp uf2(用户只需双击 reset,无时机要求)
3. **串口捕获**:⚠️ 两个坑——/dev/ttyACM* 权限(重枚举后 chmod 失效,以 root 跑);
   **Zephyr CDC 需要主机拉 DTR 才持续 TX**,否则一次 USB 事件后静默断流(v1 捕获器死于此时)
4. **读数**:串口里找 `bvd_sample_fetch: ADC raw N ~ X mV => Y mV; Percent: P`
   ——Y 才是电池真实电压,% 是 ZMK 直线换算结果。另配广播时间线(batt-recorder.py 记 status.json)

### 曲线判读(实测样本)

| 形态 | 判定 |
|---|---|
| 平滑爬升(+50mV/h↑)→ 4.14V 平台 → 单次终止灯灭 | ✅ 充电正常(95min/40%→满,100mAh 预期) |
| ON=4142 / OFF=3740 方波振荡(85 次/h),静息零漂移 | ❌ 电池不在回路:充电器空载打摆。**先查开关/JST 触点**,再怀疑电池内阻 |
| 插线时 % 虚高 50 点,拔线静息掉回真实值 | 正常现象(充电抬压),插线读数一律忽略 |
| 拔线静息 ~84-86%(非 100%) | 正常:真·满电静息 ~4.15V,ZMK 直线算出 84%。保守无害,不修 |

### 增益标定(可选,本次结论:不用)

CV 平台读数/4200 = k。实测 k=0.981(±2% 内)→ 不动 overlay;超 ±2% 才用
shield overlay 覆写 `output-ohms`/`full-ohms` 修正。

### 教训

+ 「电池坏了」判决前,先排除**开关断路**——它产生的内阻假象和真老化在数据上难分(本次差点误诊)
+ 诊断期长插线场景必须拉长 `ZMK_IDLE_TIMEOUT`,否则采不到样;插着 USB 时 activity.c
  不会触发系统关机(需 `!is_usb_power_present()`),深睡行为不变
