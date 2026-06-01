export interface RulesCount {
  must_always: number;
  must_never: number;
  learned: number;
}

export interface SoulSummary {
  name: string;
  expertise: string[];
  personality: string[];
}

export interface BarrackInfo {
  path: string;
  name: string;
  description: string;
  expertise: string[];
  topics: string[];
  aib_version: string;
  session_count: number;
  active_sessions: number;
  wiki_topic_count: number;
  rules_count: RulesCount;
  soul_summary: SoulSummary;
}

export interface FileInfo {
  name: string;
  path: string;
  content: string;
  ownership: string;
  description: string;
  exists: boolean;
}

export interface SessionInfo {
  id: string;
  client: string;
  started: string;
  ended: string;
  status: string;
  task: string;
  continues: string;
}

export interface SessionDetail {
  info: SessionInfo;
  log: string[];
  decisions: string[];
  blockers: string[];
  wiki_extractions: string[];
  identity_suggestions: string[];
  raw_content: string;
}

export interface WikiTopic {
  name: string;
  file: string;
  updated: string;
  summary: string;
}

export interface WikiIndex {
  topics: WikiTopic[];
  recent_changes: string[];
}

export interface SkillCard {
  slug: string;
  name: string;
  description: string;
  aib_version?: string;
  upstream?: string;
  argument_hint?: string;
  parse_error?: string;
}

export interface SkillsIndex {
  skills: SkillCard[];
  skills_dir_exists: boolean;
}

// v1.2.0: Skills CRUD
// Hyphen keys (argument-hint / allowed-tools) match the Rust SkillFrontmatterWrite YAML
// output, which deliberately uses Anthropic Agent Skills standard keys, not Rust field
// names. See spec §2.1 (Tauri-Serde-Rename-Bidirectional-Trap regression test).
export interface SkillFrontmatterWrite {
  name: string;
  description: string;
  "argument-hint"?: string;
  "allowed-tools"?: string;
  aib_version?: string;
  upstream?: string;
  growth_origin?: string;
  // Custom user-defined frontmatter fields. Wire format: serde_yaml::Mapping → arbitrary keys.
  custom?: Record<string, unknown>;
}

export type SkillEditorMode = "form" | "raw";

export interface SkillSaveResult {
  saved: true;
  syncOk: boolean;
  syncError?: string;  // stderr first line if syncOk === false
}

export interface SyncResult {
  path: string;
  success: boolean;
  output: string;
}

export interface RulesData {
  must_always: string[];
  must_never: string[];
  learned: string[];
}

export interface SearchResult {
  barrack: string;
  source: string;
  title: string;
  snippet: string;
  file_path: string;
}

export interface GitStatus {
  is_repo: boolean;
  git_root: string;
  is_sub_path: boolean;
  branch: string;
  changed_files: number;
  untracked_files: number;
  staged_files: number;
  ahead: number;
  behind: number;
  remote_url: string;
  last_commit: string;
  last_commit_time: string;
}

export interface GitLogEntry {
  hash: string;
  message: string;
  author: string;
  date: string;
}

export type TabType = "overview" | "files" | "sessions" | "wiki" | "skills" | "git";

export interface TerminalSession {
  id: string;
  title: string;
  barrackPath: string;
  client?: string;
  cwd?: string;
  initialCommand?: string;
  source?: "launch" | "continue" | "monitor" | "view" | "terminal" | "council";
  autoCloseOnExit?: boolean;
  ptyId?: string;
  exited?: boolean;
  /**
   * Liveness discriminator. Absent/"live" → interactive PTY-backed terminal
   * (default; existing behavior). "archive" → dead session restored read-only
   * from persisted scrollback. Archive tabs never attach a PTY.
   */
  mode?: "live" | "archive";
  /** RFC3339 close timestamp from the scrollback meta (archive tabs only). */
  closedAt?: string;
}

/** One row from the Rust `list_archived_sessions` command (camelCase keys). */
export interface ArchivedSession {
  ptyId: string;
  cwd?: string;
  title?: string;
  closedAt?: string;
  byteLen: number;
}

/** Payload returned by the Rust `load_scrollback` command (camelCase keys). */
export interface ScrollbackPayload {
  text: string | null;
  cwd?: string;
  title?: string;
  closedAt?: string;
  byteLen: number;
}

export interface TerminalSettings {
  fontFamily: string;
  fontSize: number;
  lineHeight: number;
  cursorStyle: "block" | "underline" | "bar";
}

export type ViewMode = "single" | "split-horizontal" | "split-vertical" | "grid";

export interface SplitLayout {
  mode: ViewMode;
  slots: (string | null)[];
}

export interface LaunchCommand {
  cwd: string;
  command: string;
}

export interface QuickCommand {
  id: string;
  label: string;
  command: string;
  cwd?: string;
}

// --- Agent liveness (mirrors Rust `live::Effective` / `live::LiveState`, snake_case) ---
export type EffectiveState =
  | "working"
  | "working_stale"
  | "blocked"
  | "crashed"
  | "interrupted"
  | "done"
  | "idle"
  | "none";

export interface LiveState {
  session_id: string;
  effective: EffectiveState;
  state: string;
  age_sec: number;
  pid: number;
  pid_alive: boolean;
  pid_unknown: boolean;
  run_id: string; // aib writes now-pid-random; ack matches this verbatim
}
