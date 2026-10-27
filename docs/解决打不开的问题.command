#!/bin/bash
# 右键本文件 -> 打开（第一次需要这样），它会：
# 1) 清掉下载隔离属性；2) 打开同目录的 HoverTranslator.app
cd "$(dirname "$0")" || exit 1
echo "正在清理 Gatekeeper 限制..."
xattr -cr "HoverTranslator.app" 2>/dev/null
xattr -cr . 2>/dev/null
echo "正在打开 HoverTranslator..."
open "HoverTranslator.app"
echo ""
echo "如果仍打不开：系统设置 -> 隐私与安全性 -> 页面下方点「仍要打开」。"
sleep 2
