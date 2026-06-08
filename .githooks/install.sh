#!/bin/sh
# 네이티브 repo 경량 하네스 hook 설치.
# clone 후 1회 실행: sh .githooks/install.sh
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push 2>/dev/null
echo "[harness] hooks installed: core.hooksPath=.githooks (main 직접 commit/push 차단)"
