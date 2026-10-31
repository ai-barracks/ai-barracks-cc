#!/bin/sh
# Deterministic screen content for the selection/copy self-test.
# Line layout (1-based rows) is mirrored in SelectionSuite.Fixture.
printf '\033[2J\033[1;1H'
printf 'alpha beta gamma\r\n'
printf '한글 선택 테스트 가나다\r\n'
printf 'emoji 🙂 wide 漢字 end\r\n'
printf 'trailing spaces   \r\n'
# One logical line longer than any test width: must copy back as one line.
printf 'LONG:'
i=0
while [ "$i" -lt 30 ]; do
  printf 'abcdefghij'
  i=$((i + 1))
done
printf '\r\n'
printf 'READY-SELECTION\r\n'
if [ -n "${AIBCC_READY_FILE:-}" ]; then : > "$AIBCC_READY_FILE"; fi
exec sleep 3600
