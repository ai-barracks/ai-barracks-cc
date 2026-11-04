#!/usr/bin/env bash
# Builds demo barracks for screenshots (README) in a temp folder with real
# aib (init + sync), fully isolated: aib's registry and the Claude/Gemini
# settings aib init edits are redirected into the demo folder, so nothing
# of the user's (~/.aib, ~/.claude, ~/.gemini) is touched.
#   usage: scripts/make-demo.sh [DIR]   (default /tmp/aibcc-demo)
# Prints the registry path; run the app with AIB_REGISTRY set to it.
set -eo pipefail  # no -u: bash 3.2 treats an empty array as unbound

DEMO="${1:-/tmp/aibcc-demo}"
case "$DEMO" in /tmp/*|/private/tmp/*) ;; *) echo "demo dir must be under /tmp" >&2; exit 1 ;; esac
rm -rf "$DEMO"
mkdir -p "$DEMO"
export AIB_REGISTRY="$DEMO/barracks.json" AIB_REGISTER_FORCE=1
export AIB_CLAUDE_SETTINGS="$DEMO/.claude-settings.json" AIB_GEMINI_SETTINGS="$DEMO/.gemini-settings.json"
echo '[]' > "$AIB_REGISTRY"
NOW=$(date +%s)

barrack() {   # name description
  local dir="$DEMO/$1"
  zsh -lc "aib init '$dir'" >/dev/null 2>&1
  # Before sync: sync re-registers the barrack with agent.yaml's description.
  sed -i '' "s|^description:.*|description: \"$2\"|" "$dir/agent.yaml"
  zsh -lc "aib sync '$dir'" >/dev/null 2>&1
}

soul() {   # dir name expertise... (| separated lists: expertise|personality|values|constraints)
  local dir="$1" name="$2"
  IFS='|' read -r expertise personality values constraints <<<"$3"
  {
    echo "<!-- AIB:SOUL:v1 — 이 구조를 유지하세요. 내용은 자유롭게 수정 가능합니다. -->"
    echo "# Agent Identity"; echo; echo "## Name"; echo "$name"; echo
    for section in "Expertise:$expertise" "Personality:$personality" "Core Values:$values" "Constraints:$constraints"; do
      echo "## ${section%%:*}"
      IFS=';' read -ra items <<<"${section#*:}"
      for item in "${items[@]}"; do echo "- $item"; done
      echo
    done
    echo "<!-- AIB:SOUL:END -->"
  } > "$dir/SOUL.md"
}

session() {   # dir id client started status task log-lines(;) decisions(;)
  local dir="$1" id="$2"
  IFS=';' read -ra logs <<<"$7"
  IFS=";" read -ra decisions <<<"${8:-}"
  {
    echo "<!-- AIB:OWNERSHIP — [RECORD] 에이전트가 세션 중 기록하는 파일. 세션 종료 후 수정 금지 (영구 보존). -->"
    echo "# Session: $id"; echo
    echo "- **Client**: $3"; echo "- **Started**: $4"; echo "- **Ended**: ${9:-(active)}"; echo "- **Status**: $5"
    echo "- **Task**: $6"; echo "- **Continues**: (없음)"; echo
    echo "## Log"; for line in "${logs[@]}"; do echo "- $line"; done; echo
    echo "## Decisions"; for line in "${decisions[@]}"; do echo "- $line"; done; echo
    echo "## Blockers"; echo; echo "## Retries"; echo
    echo "## Wiki Extractions"; echo "- wiki/topics/deploy-runbook.md — 배포 순서와 롤백 기준 추가"
  } > "$dir/sessions/$id.md"
}

seal() {   # dir id
  mkdir -p "$1/sessions/.seals"
  (cd "$1" && shasum -a 256 "sessions/$2.md" > "sessions/.seals/$2.sha256")
}

live() {   # dir id state pid age-seconds
  mkdir -p "$1/sessions/.live"
  local ts=$((NOW - $5))
  cat > "$1/sessions/.live/$2.status" <<JSON
{"version":1,"session_id":"$2","run_id":"$ts-$4","state":"$3","event":"demo","reason":"demo","source":"claude_hook","confidence":"high","comm":"claude","cwd":"$1","ts":$ts,"pid":$4}
JSON
}

topic() {   # dir file title summary body
  echo -e "# $3\n\n$5" > "$1/wiki/topics/$2"
  echo "| $3 | [$2](topics/$2) | 2026-11-02 | $4 |" >> "$1/wiki/Index.md"
}

# --- web_service: the main stage --------------------------------------------
W="$DEMO/web_service"
barrack web_service "쇼핑몰 웹 서비스 개발·운영"
soul "$W" "web_service Assistant" "TypeScript·Next.js;결제·주문 도메인;PostgreSQL;관측성(OpenTelemetry)|간결한 답변;근거와 함께 제안|정확성: 불확실하면 표시;안전성: 배포 전 확인;작게 자주 배포|비밀정보 출력 금지;확인 없이 프로덕션 변경 금지"
cat > "$W/RULES.md" <<'EOF'
<!-- AIB:OWNERSHIP — [AUTO-GROW] 세션에서 학습한 행동 규칙. 에이전트가 덧붙인다. -->
# Rules

## Must Always
- [2026-10-28] 결제 API 변경은 계약 테스트(pact)를 먼저 고친다 — source: claude-20261028-0910
- [2026-10-30] DB 마이그레이션은 expand → migrate → contract 3단계로 나눈다 — source: codex-20261030-1402

## Must Never
- [2026-10-29] 금요일 18시 이후 프로덕션 배포 금지 — source: 사용자 지시

## Learned
- [2026-10-31] Next.js ISR 캐시는 배포 후 revalidateTag로 비운다(경로 재검증만으로는 남음) — source: claude-20261031-1630
- [2026-11-01] 주문 목록 N+1은 include 대신 dataloader로 묶는다 — source: claude-20261101-1015
EOF
mkdir -p "$W/wiki/topics" "$W/docs/design" "$W/resources/council" "$W/skills/release-notes" "$W/src"
topic "$W" deploy-runbook.md "배포 런북" "카나리 10%→50%→100%, 롤백 기준(p95·오류율)" "## 순서\n1. 카나리 10% (15분)\n2. 50% (30분)\n3. 100%\n\n## 롤백 기준\n| 지표 | 임계값 |\n|---|---|\n| p95 지연 | 800ms 초과 5분 |\n| 5xx 비율 | 1% 초과 |"
topic "$W" api-design.md "API 설계 원칙" "REST 리소스 규칙, 페이지네이션, 오류 형식" "- 커서 페이지네이션(\`?cursor=\`)\n- 오류: \`{code, message, traceId}\`\n- 금액은 정수(원)"
topic "$W" incident-2026-10.md "장애 회고 2026-10" "결제 웹훅 중복 처리 — 멱등 키 도입" "## 원인\n웹훅 재전송 시 주문 상태가 두 번 전이.\n\n## 조치\n- 멱등 키(\`Idempotency-Key\`) 저장\n- 재현 테스트 추가"
cat > "$W/docs/design/checkout-redesign.md" <<'EOF'
# 결제 화면 개편 — 설계

> 상태: 검토 중 · 작성: Claude (세션 claude-20261103-0930)

## 목표
- 결제 단계 4 → 2단계 (배송지·결제수단 한 화면)
- 결제 실패 시 장바구니 유지, 재시도 1클릭

## 측정
| 지표 | 현재 | 목표 |
|---|---|---|
| 결제 완료율 | 61.2% | **68%** |
| 결제 단계 이탈 | 23.5% | 15% |
| p95 결제 API | 640ms | 400ms |

## 단계
1. 결제수단 컴포넌트 분리 (`CheckoutPayment`)
2. 주소 자동완성 API 연동
3. A/B 테스트 2주 (트래픽 20%)

## 위험
- PG사 SDK가 iframe 높이를 고정 → 레이아웃 재검증 필요
EOF
cat > "$W/docs/plan.md" <<'EOF'
# 11월 계획

- [x] 주문 목록 N+1 제거
- [ ] 결제 화면 개편 (docs/design/checkout-redesign.md)
- [ ] 관측성: 결제 API 트레이스 샘플링 10%
EOF
cat > "$W/skills/release-notes/SKILL.md" <<'EOF'
---
name: release-notes
description: "Use when preparing a release: collect merged PRs since the last tag and draft Korean release notes grouped by feature/fix."
argument-hint: "[since-tag]"
allowed-tools: Bash(git log *), Bash(gh pr list *), Read, Write
aib_version: "1.1"
growth_origin: "manual"
---

# Release Notes

## When to invoke
- 태그를 만들기 직전, 사용자가 "릴리즈 노트" 요청 시

## How
1. `git log <since-tag>..HEAD --merges`로 PR 목록 수집
2. feat / fix / chore로 묶어 한국어로 요약
3. `docs/releases/<version>.md`에 저장
EOF
cat > "$W/resources/council/20261102-1410-council.md" <<'EOF'
# Council: 결제 실패 재시도 — 클라이언트 vs 서버

- 모드: debate · 2 라운드 · 합의도 **84**
- 참여: Claude, Codex

## 합의안
서버가 멱등 키로 재시도를 판정하고, 클라이언트는 상태 조회만 한다.

## 근거
| 관점 | Claude | Codex |
|---|---|---|
| 중복 결제 위험 | 서버 판정이 유일한 방어선 | 동의 |
| 구현 비용 | 키 저장소 필요 | 기존 Redis 재사용 가능 |

## 미합의
- 재시도 상한(3회 vs 5회) — 사용자 결정
EOF
cat > "$W/src/checkout.ts" <<'EOF'
export async function submitOrder(cart: Cart, payment: Payment) {
  return api.post("/orders", { cart, payment }, { idempotencyKey: cart.id })
}
EOF
session "$W" claude-20261101-1015 "Claude Code" "2026-11-01 10:15" completed "주문 목록 N+1 제거" "[10:20] 쿼리 로그 분석 → 주문당 3회 추가 쿼리;[10:48] dataloader 도입 → p95 420ms→180ms;[11:05] 회귀 테스트 추가, PR #142" "include 대신 dataloader — 페이지 크기와 무관하게 쿼리 2회" "2026-11-01 11:10"
seal "$W" claude-20261101-1015
session "$W" codex-20261102-1400 "Codex" "2026-11-02 14:00" completed "결제 재시도 정책 Council" "[14:10] council debate 2라운드 → 합의도 84;[14:35] 멱등 키 설계안 정리" "재시도 판정은 서버(멱등 키)" "2026-11-02 14:40"
seal "$W" codex-20261102-1400
session "$W" claude-20261103-0930 "Claude Code" "2026-11-03 09:30" active "결제 화면 개편 설계" "[09:40] 퍼널 데이터 확인 → 결제 단계 이탈 23.5%;[10:05] 설계 초안 docs/design/checkout-redesign.md" "결제수단 컴포넌트를 먼저 분리"
(cd "$W" && git init -q -b main && git add -A && git -c user.name=Demo -c user.email=demo@example.com commit -qm "chore: barrack init" \
  && echo "export const MAX_RETRY = 3" >> src/checkout.ts && git add -A && git -c user.name=Demo -c user.email=demo@example.com commit -qm "feat: 결제 재시도 상한" \
  && echo "- [ ] 주소 자동완성" >> docs/plan.md && touch src/address.ts)

# --- other barracks: liveness states for the sidebar ------------------------
sleep 7200 >/dev/null 2>&1 &   # a live pid so "blocked" stays blocked
ALIVE=$!
echo "$ALIVE" > "$DEMO/.demo-pid"
D="$DEMO/data_platform"; barrack data_platform "데이터 파이프라인·웨어하우스"
soul "$D" "data_platform Assistant" "ClickHouse;Airflow;dbt|간결한 답변|정확성;재현성|프로덕션 테이블 DROP 금지"
session "$D" claude-20261103-0855 "Claude Code" "2026-11-03 08:55" active "주간 매출 마트 재구축" "[09:00] dbt 모델 의존성 정리;[09:20] 백필 범위 확인 요청"
live "$D" claude-20261103-0855 blocked "$ALIVE" 190
M="$DEMO/ml_research"; barrack ml_research "추천 모델 실험"
soul "$M" "ml_research Assistant" "PyTorch;추천 시스템;실험 설계|근거 중심|재현성|개인정보 원본 반출 금지"
session "$M" codex-20261103-0700 "Codex" "2026-11-03 07:00" completed "오프라인 평가 리포트" "[07:10] NDCG@10 0.412→0.437" "" "2026-11-03 08:30"
live "$M" codex-20261103-0700 done "$ALIVE" 600
I="$DEMO/infra_ops"; barrack infra_ops "인프라·배포 자동화"
soul "$I" "infra_ops Assistant" "Kubernetes;Terraform;GitHub Actions|신중함|안전성|확인 없이 apply 금지"

echo "$AIB_REGISTRY"
