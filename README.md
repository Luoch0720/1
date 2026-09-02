# TelegramVoiceNoteTweak

在 Telegram iOS 中把本地音频文件（Ogg Opus）作为语音消息发送。

## 原理

1. 悬浮按钮选择本地 `.ogg` 文件 → 存为待发送
2. Hook `ManagedAudioRecorderImpl` 的录音停止方法
3. 录音停止后，把录音文件替换成你选的文件
4. 你正常点发送，Telegram 上传并发出替换后的文件
5. 对方收到的就是一条普通语音消息

## 环境要求

- 越狱 iOS 设备（Dopamine / checkra1n / palera1n 等）
- Telegram 12.9.x（其他版本需验证类名）
- 编译环境：WSL2 Ubuntu + Theos，或 macOS + Theos

## 编译步骤（WSL2）

### 1. 安装 Theos

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

### 2. 安装 iOS SDK

下载 iPhoneOS SDK（推荐 15.0 以上），放到 `$THEOS/sdks/`：

```bash
# 从 https://github.com/xybp888/iOS-SDKs 下载
# 例如 iPhoneOS16.4.sdk
mv iPhoneOS16.4.sdk $THEOS/sdks/
```

### 3. 编译

```bash
cd TelegramVoiceNoteTweak
make package THEOS_PACKAGE_SCHEME=rootless
```

编译成功后，`.deb` 包在 `packages/` 目录。

### 4. 安装到手机

方式一：直接复制到手机安装
```bash
scp packages/com.user.telegramvoicenotetweak_0.1.0_iphoneos-arm64.deb root@<手机IP>:/tmp/
ssh root@<手机IP> "dpkg -i /tmp/com.user.telegramvoicenotetweak_0.1.0_iphoneos-arm64.deb"
```

方式二：用 Sileo/Zebra 手动安装 deb 文件。

安装后 **respring** 或重启 Telegram。

## 使用方法

1. 打开 Telegram，屏幕右侧会出现一个蓝色悬浮按钮（🎤），可以拖动位置
2. 点击悬浮按钮，选择本地 `.ogg` 音频文件
3. 弹出"假语音已就绪"提示
4. 进入任意聊天，**按麦克风按钮随便录一句**（对着静音也行，至少 1 秒）
5. 点发送
6. 实际发出的是你选的那个音频文件

## 音频格式要求

必须是 **Ogg 容器 + Opus 编码，单声道，48kHz**。

用 ffmpeg 转换：
```bash
ffmpeg -i input.mp3 -c:a libopus -b:a 32k -ac 1 -ar 48000 output.ogg
```

## 文件说明

| 文件 | 作用 |
|------|------|
| `Tweak.xm` | 主入口，hook 录音器方法 |
| `FakeVoiceManager.h/m` | 核心逻辑：悬浮按钮、文件选择、录音文件替换 |
| `Makefile` | Theos 编译配置 |
| `control` | deb 包信息 |
| `TelegramVoiceNoteTweak.plist` | 注入过滤（只注入 Telegram） |

## 调试

查看日志：
```bash
# 越狱设备上
ssh root@<手机IP>
log show --predicate 'process == "Telegram"' --last 10m | grep FakeVoice
# 或
screendump && cat /var/log/syslog | grep FakeVoice
```

关键日志标记：
- `[FakeVoice] === TelegramVoiceNoteTweak loaded ===` — Tweak 加载成功
- `[FakeVoice] hooked: ManagedAudioRecorderImpl [stopRecordingWithCompletion:]` — Hook 成功
- `[FakeVoice] found recording path via ...` — 找到录音文件路径
- `[FakeVoice] SUCCESS: replaced recording file with fake voice` — 替换成功
- `[FakeVoice] ERROR: could not locate recording file path` — 找不到录音文件，需调试

## 如果 Hook 失败

不同 Telegram 版本类名/方法名可能变化。用 Frida 验证：

```bash
# 手机上安装 frida，电脑上运行
frida -U -n Telegram -l probe.js
```

probe.js 内容：
```javascript
if (ObjC.available) {
  // 找录音相关的类
  for (const name of Object.keys(ObjC.classes)) {
    if (/Audio|Voice|Record/i.test(name)) {
      console.log(name);
    }
  }
}
```

找到正确的类名后，修改 `Tweak.xm` 里的 `classCandidates` 数组。

## 注意事项

- **账号风险**：注入修改客户端违反 Telegram 服务条款，建议先用小号测试
- **最短时长**：语音消息通常至少 1 秒，文件太短可能发送失败
- **版本兼容**：Telegram 大版本更新后 hook 点可能失效，需重新验证
- **悬浮按钮**：在任何界面都显示，不影响正常操作，可拖动到角落

## 技术细节

### Hook 的方法

基于 Telegram 12.9.3 二进制分析：

| 方法 | 作用 |
|------|------|
| `stopRecordingWithCompletion:` | 停止录音（主 hook 点） |
| `finishRecording:` | 完成录音（备选） |
| `endRecording` | 结束录音（备选） |
| `sendRecordedMedia` | 发送录制媒体（发送后清除状态） |

### 录音文件定位策略

1. KVC 尝试常见属性名（`recordingURL`、`outputPath` 等）
2. 直接扫描 ivar 列表
3. 在 tmp 目录找最新的 `.ogg` 文件（兜底）

三种方式依次尝试，确保能定位到录音文件。
