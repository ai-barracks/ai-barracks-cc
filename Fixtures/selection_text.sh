#!/bin/sh
# Deterministic screen content for the selection/copy self-test.
# Line layout (1-based rows) is mirrored in SelectionSuite.Fixture.
printf '\033[2J\033[1;1H'
printf 'alpha beta gamma\r\n'
printf '한글 선택 테스트 가나다\r\n'
printf 'emoji 🙂 wide 漢字 end\r\n'
printf 'trailing spaces   \r\n'
# A wide character that does not fit at the end of a row must wrap whole and
# copy back contiguous: (cols - 1) ASCII cells, then two wide characters.
cols=$(stty size 2>/dev/null | cut -d' ' -f2)
cols=${cols:-80}
fill=$((cols - 1))
j=0
while [ "$j" -lt "$fill" ]; do
  printf 'w'
  j=$((j + 1))
done
printf '漢字\r\n'
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
