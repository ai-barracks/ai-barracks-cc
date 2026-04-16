export interface EmbeddedSession {
  id: string;
  title: string;
  cwd?: string;
  initialCommand?: string;
}

export interface EmbeddedTerminalState {
  sessions: EmbeddedSession[];
  activeId: string | null;
  panelWidth: number;
  isExpanded: boolean;
}

export type EmbeddedTerminalAction =
  | { type: "ADD_SESSION"; session: EmbeddedSession }
  | { type: "REMOVE_SESSION"; id: string }
  | { type: "SET_ACTIVE"; id: string }
  | { type: "SET_WIDTH"; width: number }
  | { type: "RESET" };

export const INITIAL_EMBEDDED_STATE: EmbeddedTerminalState = {
  sessions: [],
  activeId: null,
  panelWidth: 480,
  isExpanded: false,
};

export function embeddedTerminalReducer(
  state: EmbeddedTerminalState,
  action: EmbeddedTerminalAction
): EmbeddedTerminalState {
  switch (action.type) {
    case "ADD_SESSION": {
      const exists = state.sessions.some((s) => s.id === action.session.id);
      if (exists) return { ...state, activeId: action.session.id };
      return {
        ...state,
        sessions: [...state.sessions, action.session],
        activeId: action.session.id,
        isExpanded: true,
        panelWidth: state.panelWidth < 200 ? 480 : state.panelWidth,
      };
    }
    case "REMOVE_SESSION": {
      const remaining = state.sessions.filter((s) => s.id !== action.id);
      const nextActive =
        state.activeId === action.id
          ? (remaining[remaining.length - 1]?.id ?? null)
          : state.activeId;
      return {
        ...state,
        sessions: remaining,
        activeId: nextActive,
        isExpanded: remaining.length > 0,
      };
    }
    case "SET_ACTIVE":
      return { ...state, activeId: action.id };
    case "SET_WIDTH":
      return { ...state, panelWidth: action.width };
    case "RESET":
      return { ...INITIAL_EMBEDDED_STATE };
    default:
      return state;
  }
}
