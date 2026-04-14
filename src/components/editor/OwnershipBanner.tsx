const OWNERSHIP_INFO: Record<
  string,
  { color: string; bg: string; border: string; label: string; description: string; action: string }
> = {
  "직접 편집": {
    color: "text-blue-500",
    bg: "bg-blue-500/8",
    border: "border-blue-500/15",
    label: "직접 편집",
    description: "사용자가 직접 관리하는 파일입니다.",
    action: "배럭에 맞게 내용을 수정하세요. 에이전트는 이 파일을 읽기만 합니다.",
  },
  "자동 축적": {
    color: "text-green-500",
    bg: "bg-green-500/8",
    border: "border-green-500/15",
    label: "자동 축적",
    description: "에이전트가 세션마다 자동으로 추가하는 파일입니다.",
    action: "내버려 두어도 됩니다. 필요 시 규칙을 직접 추가/삭제할 수 있습니다.",
  },
  "aib 관리": {
    color: "text-purple-500",
    bg: "bg-purple-500/8",
    border: "border-purple-500/15",
    label: "aib 관리",
    description: "aib CLI가 관리하는 메타데이터 파일입니다.",
    action: "이름과 설명은 자유롭게 수정 가능. 모델 설정도 여기서 변경합니다.",
  },
};

export function OwnershipBanner({ ownership }: { ownership: string }) {
  const info = OWNERSHIP_INFO[ownership];
  if (!info) return null;

  return (
    <div
      className={`flex items-center gap-3 px-4 py-2.5 ${info.bg} border-b ${info.border}`}
    >
      <span
        className={`text-[11px] font-semibold px-2 py-0.5 rounded ${info.color} ${info.bg}`}
      >
        {info.label}
      </span>
      <span className="text-[12px] text-cc-text-dim">
        {info.description}
      </span>
      <span className="text-[12px] text-cc-text-muted">
        {info.action}
      </span>
    </div>
  );
}
