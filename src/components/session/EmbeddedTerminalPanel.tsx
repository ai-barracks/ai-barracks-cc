import { useEmbeddedTerminalResize } from "../../hooks/useEmbeddedTerminalResize";
import { EmbeddedTerminalTabBar } from "./EmbeddedTerminalTabBar";
import { EmbeddedTerminalInstance } from "./EmbeddedTerminalInstance";
import type { EmbeddedTerminalState, EmbeddedTerminalAction } from "./embeddedTerminalReducer";

interface EmbeddedTerminalPanelProps {
  state: EmbeddedTerminalState;
  dispatch: React.Dispatch<EmbeddedTerminalAction>;
}

export function EmbeddedTerminalPanel({ state, dispatch }: EmbeddedTerminalPanelProps) {
  const { handleMouseDown } = useEmbeddedTerminalResize({
    currentWidth: state.panelWidth,
    onWidthChange: (width) => dispatch({ type: "SET_WIDTH", width }),
  });

  return (
    <div className="flex flex-row flex-shrink-0 border-l border-cc-border" style={{ width: state.panelWidth }}>
      {/* 드래그 리사이즈 핸들 */}
      <div
        onMouseDown={handleMouseDown}
        className="w-1 cursor-col-resize bg-cc-border hover:bg-cc-accent transition-colors flex-shrink-0"
      />

      {/* 터미널 컨테이너 */}
      <div className="flex flex-col flex-1 overflow-hidden bg-cc-bg">
        <EmbeddedTerminalTabBar
          sessions={state.sessions}
          activeId={state.activeId}
          onSelect={(id) => dispatch({ type: "SET_ACTIVE", id })}
          onClose={(id) => dispatch({ type: "REMOVE_SESSION", id })}
        />
        <div className="flex-1 relative overflow-hidden">
          {state.sessions.map((s) => (
            <EmbeddedTerminalInstance
              key={s.id}
              session={s}
              visible={s.id === state.activeId}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
