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

export type TabType = "overview" | "files" | "sessions" | "wiki" | "git";
