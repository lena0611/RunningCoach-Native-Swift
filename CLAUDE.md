# CLAUDE — RunningCoach 네이티브(iOS) repo

이 파일은 네이티브 iOS 프로젝트에서 작업하는 모든 에이전트의 진입점입니다.
웹(PaceLAB) 하네스와 별도지만, 같은 제품의 네이티브 래퍼이므로 디시플린을 맞춥니다.

## repo 정체 / 디렉터리 구조 (중요)
- 이 repo 루트 = `/Users/smart-tn-083/practice/RunningCoach/RunningCoach/`
- remote = `github.com/lena0611/RunningCoach-Native-Swift` (네이티브 전용)
- 폴더가 2중첩(`RunningCoach/RunningCoach/`)이다. **바깥 `RunningCoach/`는 컨테이너일 뿐 `.git`이 없다.**
- 과거 최상위 `practice/`에 커밋 0·remote 없는 쓰레기 catch-all `.git`이 있어, 바깥 레벨에서 git 명령을 돌리면 그 쓰레기 repo가 잡혀 "네이티브는 git 관리 안 됨"으로 오진되곤 했다. 이 catch-all은 `practice/.git.disabled-catchall`로 비활성화했다.
- git 명령은 **반드시 이 repo 루트(또는 하위)에서** 실행하고, `git rev-parse --show-toplevel`로 올바른 repo인지 먼저 확인한다.

## 커밋 / 브랜치 디시플린
- `main`은 머지·배포 기준. 작업은 feature branch + PR(기존 관행: PR #1, #2)로 한다. main 직접 커밋 지양.
- **세션 종료 시 working tree에 미커밋 변경(WIP)을 남기지 않는다.** 이게 과거 auth/VO2max/세로고정 작업이 추적 누락된 원인이다.
- 한 PR/커밋에 무관한 기능을 섞지 않는다. 부득이 한 파일에 여러 기능이 섞이면 hunk 단위로 분리 커밋한다.

## iOS 전용 완료 흐름 (웹과 다름)
- 웹은 main 머지 → GitHub Pages 자동배포가 "완료" 체크포인트를 만든다. **iOS는 자동배포가 없다** — Xcode 재빌드 + 기기 설치(사용자만 가능)가 검증 수단이다.
- 따라서 **커밋과 기기 검증을 분리한다**: 코드 작성이 끝나면 (기기 검증 전이라도) feature branch에 **즉시 커밋해 유실을 막고**, 이후 사용자가 Xcode 재빌드·기기 설치로 검증한 뒤 머지한다.
- "기기 검증 대기"를 이유로 커밋을 무기한 보류하지 않는다.

## 웹(PaceLAB)과의 계약
- 웹 프론트는 별도 repo `lena0611/RunningCoach`(run-ai). 자체 `.harness`/git hook 보유.
- HealthKit/세션상세/스플릿/케이던스/route/자동동기화 관련 네이티브 변경은 웹 쪽 데이터 계약(run-ai의 `.harness/project/healthkit-data-contract.md`)과 양방향으로 맞춘다.
- WebView 브리지 식별자(`window.RunContextHealthKit`, `window.RunContextAuth` 등)는 웹과 네이티브 양쪽을 함께 수정한다.

## git hook (경량 안전장치)
- `.githooks/`에 `xcodebuild` 없는 경량 hook이 있다. clone 후 1회 `sh .githooks/install.sh`로 설치(`core.hooksPath=.githooks`).
- `pre-commit`: `main` 직접 커밋 차단. `pre-push`: `main` 직접 push 차단. 예외는 `HARNESS_ALLOW_MAIN_COMMIT=1` / `HARNESS_ALLOW_MAIN_PUSH=1`.
- 무거운 빌드 검증은 hook에 넣지 않는다. iOS 검증은 Xcode 재빌드/기기 설치로 분리한다(위 "iOS 전용 완료 흐름").

## git 위생
- `.gitignore`로 Xcode 산출물(`*.xcuserstate`, `DerivedData/`, `build/`, `xcuserdata/`)과 생성된 웹 번들(`RunningCoach/WebApp/`)을 제외한다. 추적된 산출물이 없도록 유지한다.
