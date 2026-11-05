# AI Barracks CommandCenter 2 — 설치

v2는 v1(CommandCenter 1.x, Tauri)과 **나란히 설치**된다. 번들 ID가 다르므로(`com.aibarracks.commandcenter2`) 설정·세션 저장 위치가 섞이지 않는다.

## 릴리즈에서 설치

[Releases](https://github.com/ai-barracks/ai-barracks-cc/releases)의 `v2.*`에서 DMG를 받아 앱을 `/Applications`로 끌어 놓은 뒤, 내려받은 앱의 격리 속성을 지운다(ad-hoc 서명, 공증 없음):

```bash
xattr -cr "/Applications/AI Barracks CommandCenter 2.app"
```

## 빌드·설치 (로컬)

```bash
VARIANT=release ./scripts/package-app.sh     # dist/release/AI Barracks CommandCenter 2.app (release 빌드, ad-hoc 서명)
./scripts/make-dmg.sh                        # dist/release/AI-Barracks-CommandCenter-<버전>.dmg (+ SHA-256)
```

DMG를 열어 앱을 `/Applications`로 끌어 놓는다. ad-hoc 서명이라 첫 실행은 Finder에서 우클릭 → 열기.

요구 사항: macOS 14+, `aib` CLI(1.6.0+)가 로그인 셸 PATH에 있을 것(`~/.local/bin` 등). Claude Code·Codex·Gemini CLI는 쓰는 것만.

## 데이터 위치

| 무엇 | 위치 |
|---|---|
| 설정(글꼴·커서·모델 프로필·Quick Commands) | `defaults read com.aibarracks.commandcenter2` |
| PTY 데몬 소켓·저장된 터미널 배치·터미널 출력 보관 | `~/Library/Application Support/CommandCenter2/` |
| 예약 활성화 설정·기록 | `~/Library/Application Support/com.aibarracks.commandcenter/activation.json` — **v1과 공유**(아래) |
| 배럭 목록 | `~/.aib/barracks.json` (aib가 관리) |

개발 빌드(`AIBCC-PoC.app`, self-test·bench용)는 `~/Library/Application Support/AIBCCPoC/`를 써서 출시 빌드와 데몬을 공유하지 않는다.

## v1과 함께 쓸 때

- **예약 활성화**: v1과 같은 파일·잠금(flock)을 쓴다. 먼저 뜬 앱이 예약을 맡고, 다른 앱은 설정 화면에 "다른 CommandCenter가 예약을 맡고 있습니다"를 보여 준다. 같은 시각이 두 번 실행되지 않는다. v1을 끄면 v2가 다음 실행부터 맡는다.
- **설정 가져오기**: 설정 → v1에서 가져오기 — v1의 Quick Commands·터미널 글꼴/커서·모델 프로필을 읽기 전용으로 읽어 온다.
- 터미널 세션은 공유하지 않는다(v1은 앱 안 PTY, v2는 자체 데몬).

## 제거

앱을 휴지통으로 옮기고, 원하면 `~/Library/Application Support/CommandCenter2/`와 `defaults delete com.aibarracks.commandcenter2`. 예약 파일은 v1 것이므로 건드리지 않는다.
