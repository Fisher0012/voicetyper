#!/bin/bash
# VoiceTyper 一键安装脚本
# 假设当前在 voicetyper 仓库根目录下运行
# 步骤:xcodegen → xcodebuild Release → 备份旧版 → 部署到 /Applications → 重签 → 启动
#
# 用户用法(推荐):在 Claude Code 里用 voicetyper-install skill,会自动调用本脚本。
# 手动用法:cd ~/Developer/voicetyper && bash scripts/install.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VoiceTyper"
INSTALL_PATH="/Applications/${APP_NAME}.app"
DERIVED_DATA="${PROJECT_DIR}/build-release"

cd "$PROJECT_DIR"

echo "==================================================="
echo "  VoiceTyper 安装"
echo "==================================================="
echo "项目:    $PROJECT_DIR"
echo "目标:    $INSTALL_PATH"
echo

# 1. 前置检查
echo "[1/6] 前置检查..."
if [ "$(uname -m)" != "arm64" ]; then
  echo "✗ 错误:只支持 Apple Silicon (arm64)。本机是 $(uname -m)。"
  exit 1
fi

if ! command -v xcodebuild &> /dev/null; then
  echo "✗ 错误:未找到 xcodebuild。请从 App Store 安装 Xcode。"
  exit 1
fi

if ! command -v xcodegen &> /dev/null; then
  echo "[安装] xcodegen..."
  if command -v brew &> /dev/null; then
    brew install xcodegen
  else
    echo "✗ 错误:需要 Homebrew 才能装 xcodegen。访问 https://brew.sh"
    exit 1
  fi
fi

CERT="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')"
if [ -z "$CERT" ]; then
  echo "⚠️  未找到 Apple Development 签名证书。"
  echo "    建议在 Xcode → Settings → Accounts 登录 Apple ID(免费即可)。"
  echo "    现在用 ad-hoc 签名继续(注意:ad-hoc app 权限授权后,下次替换 .app 文件可能丢失,"
  echo "    需要重新授权 Accessibility)。"
  SIGN_IDENTITY="-"
else
  echo "✓ 找到证书: $CERT"
  SIGN_IDENTITY="$CERT"
fi
echo

# 2. 生成 Xcode 工程
echo "[2/6] xcodegen generate..."
xcodegen generate > /tmp/voicetyper-gen.log 2>&1 || {
  echo "✗ xcodegen 失败,完整输出:"
  cat /tmp/voicetyper-gen.log
  exit 1
}
echo "✓"
echo

# 3. xcodebuild
echo "[3/6] xcodebuild Release (首次约 3-5 分钟,会拉取 SPM 依赖)..."
echo "      日志:/tmp/voicetyper-build.log"
xcodebuild \
  -project GhostPepper.xcodeproj \
  -scheme GhostPepper \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  build > /tmp/voicetyper-build.log 2>&1 || {
  echo "✗ 构建失败,最后 30 行:"
  tail -30 /tmp/voicetyper-build.log
  exit 1
}
echo "✓ BUILD SUCCEEDED"
echo

# 4. 备份旧版
BUILT_APP="${DERIVED_DATA}/Build/Products/Release/GhostPepper.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "✗ 找不到构建产物: $BUILT_APP"
  exit 1
fi

echo "[4/6] 部署到 $INSTALL_PATH..."
if [ -d "$INSTALL_PATH" ]; then
  BACKUP="${HOME}/.Trash/VoiceTyper-old-$(date +%Y%m%d-%H%M%S).app"
  mv "$INSTALL_PATH" "$BACKUP"
  echo "  旧版已挪到废纸篓: $BACKUP"
fi

# 关掉旧进程
pkill -f "VoiceTyper.app/Contents/MacOS/GhostPepper" 2>/dev/null || true
sleep 1

cp -R "$BUILT_APP" "$INSTALL_PATH"
echo "✓"
echo

# 5. 签名
echo "[5/6] 用 $([ "$SIGN_IDENTITY" = "-" ] && echo 'ad-hoc' || echo '开发证书') 重签..."
xattr -cr "$INSTALL_PATH"
codesign --force --deep --preserve-metadata=entitlements \
  --sign "$SIGN_IDENTITY" \
  "$INSTALL_PATH" 2>&1 | head -3
echo "✓"
echo

# 6. 启动
echo "[6/6] 启动 VoiceTyper..."
open "$INSTALL_PATH"
sleep 2

if pgrep -f "VoiceTyper.app/Contents/MacOS/GhostPepper" > /dev/null; then
  echo "✓ VoiceTyper 已启动"
else
  echo "⚠️  启动可能失败。如果 Gatekeeper 拦了,请右键 ${INSTALL_PATH} → 打开。"
fi
echo

echo "==================================================="
echo "  ✓ 安装完成"
echo "==================================================="
echo
echo "下一步(必须):"
echo "  1. 系统设置 → 隐私与安全 → 辅助功能 → 添加 VoiceTyper(若不存在)→ 打开开关"
echo
echo "首次使用:"
echo "  • app 会下载 ~5GB 模型(Whisper Large v3 Turbo + Qwen 4B),菜单栏显示进度"
echo "  • 下完后,任何文本框里按一下右 Cmd 录音 → 说话 → 再按一下停止"
echo "  • 或说完静音 2 秒自动停(VAD)"
echo "  • 文字自动粘贴到光标处"
echo
echo "自定义术语字典:"
echo "  编辑 ~/Library/Application\\ Support/GhostPepper/custom-terms.txt"
echo "  每行一个你常用的专有名词(React、HTTPS 等)"
echo
echo "完整文档: https://github.com/Fisher0012/voicetyper"
