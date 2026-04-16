import { useState, useEffect, useRef, useMemo } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import type { LaunchCommand } from "../../types";

interface Command {
  label: string;
  description: string;
  category: "agent" | "git" | "aib" | "terminal" | "quick";
  action: () => void;
}

export function CommandPalette() {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const { selectedBarrack, barracks, setActiveTab } = useAppStore();
  const addTerminal = useTerminalStore((s) => s.addSession);
  const quickCommands = useTerminalStore((s) => s.quickCommands);
  const removeQuickCommand = useTerminalStore((s) => s.removeQuickCommand);

  const aib = "/opt/homebrew/bin/aib";
  const b = selectedBarrack;

  const commands = useMemo<Command[]>(() => {
    const cmds: Command[] = [];

    if (!b) return cmds;

    // Terminal
    cmds.push({
      label: "New Terminal",
      description: "새 셸 터미널 열기",
      category: "terminal",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: "zsh", barrackPath: b.path, cwd: b.path, source: "terminal" });
        setActiveTab("sessions");
      },
    });

    // Agent
    for (const client of ["claude", "gemini", "codex"]) {
      cmds.push({
        label: `Start ${client.charAt(0).toUpperCase() + client.slice(1)}`,
        description: `${b.name}에서 ${client} 세션 시작`,
        category: "agent",
        action: async () => {
          const cmd = await invoke<LaunchCommand>("get_launch_command", {
            barrackPath: b.path, client, skipPermissions: false,
          });
          addTerminal({
            id: crypto.randomUUID(),
            title: `${client.charAt(0).toUpperCase() + client.slice(1)} - ${b.name}`,
            barrackPath: b.path, client, cwd: cmd.cwd, initialCommand: cmd.command,
            source: "launch",
          });
          setActiveTab("sessions");
        },
      });
    }

    // AIB
    cmds.push({
      label: "aib status",
      description: "현재 배럭 상태 확인",
      category: "aib",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: `status - ${b.name}`, barrackPath: b.path, cwd: b.path, initialCommand: `${aib} status`, source: "terminal" });
        setActiveTab("sessions");
      },
    });
    cmds.push({
      label: "aib sync",
      description: "배럭 동기화 (dry-run 후 실행)",
      category: "aib",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: `Sync - ${b.name}`, barrackPath: b.path, cwd: b.path, initialCommand: `${aib} sync --dry-run '${b.path}'`, source: "terminal" });
        setActiveTab("sessions");
      },
    });
    cmds.push({
      label: "aib wiki lint",
      description: "���키 검증 (stale, 크기, 인덱스)",
      category: "aib",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: `Wiki Lint - ${b.name}`, barrackPath: b.path, cwd: b.path, initialCommand: `${aib} wiki lint`, source: "terminal" });
        setActiveTab("sessions");
      },
    });
    cmds.push({
      label: "aib council",
      description: "멀티-LLM 토론 시작",
      category: "aib",
      action: () => {
        const topic = prompt("Council 토�� 주제:");
        if (topic) {
          addTerminal({ id: crypto.randomUUID(), title: `Council`, barrackPath: b.path, cwd: b.path, initialCommand: `${aib} council "${topic}"`, source: "council" });
          setActiveTab("sessions");
        }
      },
    });

    // Git
    cmds.push({
      label: "git status",
      description: "Git 상태 확인",
      category: "git",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: "git status", barrackPath: b.path, cwd: b.path, initialCommand: "git status", source: "terminal", autoCloseOnExit: true });
        setActiveTab("sessions");
      },
    });
    cmds.push({
      label: "git diff",
      description: "변경사항 diff 보기",
      category: "git",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: "git diff", barrackPath: b.path, cwd: b.path, initialCommand: "git diff", source: "terminal", autoCloseOnExit: true });
        setActiveTab("sessions");
      },
    });
    cmds.push({
      label: "git add -p",
      description: "인터랙티브 스테이징",
      category: "git",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: "git add -p", barrackPath: b.path, cwd: b.path, initialCommand: "git add -p", source: "terminal" });
        setActiveTab("sessions");
      },
    });
    cmds.push({
      label: "git log --graph",
      description: "커밋 그래프 보기",
      category: "git",
      action: () => {
        addTerminal({ id: crypto.randomUUID(), title: "git graph", barrackPath: b.path, cwd: b.path, initialCommand: "git log --graph --oneline --all -20", source: "terminal", autoCloseOnExit: true });
        setActiveTab("sessions");
      },
    });

    // Multi-barrack
    if (barracks.length > 1) {
      cmds.push({
        label: "Sync All Barracks",
        description: `${barracks.length}개 배럭 순차 동기화`,
        category: "aib",
        action: () => {
          const syncCmd = barracks.map((br) => `echo '=== ${br.name} ===' && ${aib} sync '${br.path}'`).join(" && ");
          addTerminal({ id: crypto.randomUUID(), title: "Sync All", barrackPath: b.path, initialCommand: syncCmd, source: "terminal" });
          setActiveTab("sessions");
        },
      });
      cmds.push({
        label: "Barracks List",
        description: "등록된 배럭 목록 확인",
        category: "aib",
        action: () => {
          addTerminal({ id: crypto.randomUUID(), title: "barracks list", barrackPath: b.path, initialCommand: `${aib} barracks list`, source: "terminal", autoCloseOnExit: true });
          setActiveTab("sessions");
        },
      });
    }

    // Quick Commands (user-saved macros)
    for (const qc of quickCommands) {
      cmds.push({
        label: qc.label,
        description: qc.command.length > 60 ? qc.command.slice(0, 60) + "..." : qc.command,
        category: "quick",
        action: () => {
          addTerminal({
            id: crypto.randomUUID(),
            title: qc.label,
            barrackPath: b.path,
            cwd: qc.cwd || b.path,
            initialCommand: qc.command,
            source: "terminal",
          });
          setActiveTab("sessions");
        },
      });
    }
    if (quickCommands.length > 0) {
      cmds.push({
        label: "Manage Quick Commands",
        description: "저장된 Quick Command 삭제",
        category: "quick",
        action: () => {
          const list = quickCommands.map((c, i) => `${i + 1}. ${c.label}`).join("\n");
          const idx = prompt(`삭제할 번호를 입력하세요:\n${list}`);
          if (idx) {
            const n = parseInt(idx, 10) - 1;
            if (quickCommands[n]) removeQuickCommand(quickCommands[n].id);
          }
        },
      });
    }

    return cmds;
  }, [b, barracks, addTerminal, quickCommands, removeQuickCommand, setActiveTab]);

  const filtered = query
    ? commands.filter(
        (c) =>
          c.label.toLowerCase().includes(query.toLowerCase()) ||
          c.description.toLowerCase().includes(query.toLowerCase())
      )
    : commands;

  useEffect(() => {
    setSelectedIndex(0);
  }, [query]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.metaKey && e.key === "k") {
        e.preventDefault();
        setOpen((v) => !v);
        setQuery("");
      }
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  const handleSelect = (cmd: Command) => {
    cmd.action();
    setOpen(false);
    setQuery("");
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIndex((i) => Math.min(i + 1, filtered.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter" && filtered[selectedIndex]) {
      handleSelect(filtered[selectedIndex]);
    }
  };

  if (!open) return null;

  const CATEGORY_LABELS: Record<string, string> = {
    agent: "Agent",
    git: "Git",
    aib: "AIB",
    terminal: "Term",
    quick: "Quick",
  };

  const CATEGORY_COLORS: Record<string, string> = {
    agent: "text-orange-400",
    git: "text-cc-success",
    aib: "text-cc-accent",
    terminal: "text-cc-text-dim",
    quick: "text-cc-warning",
  };

  return (
    <div
      className="fixed inset-0 z-[100] flex items-start justify-center pt-[15vh]"
      onClick={() => setOpen(false)}
    >
      <div
        className="w-[480px] bg-cc-panel border border-cc-border rounded-xl shadow-2xl overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="px-4 py-3 border-b border-cc-border">
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a command..."
            className="w-full text-[14px] bg-transparent text-cc-text placeholder:text-cc-text-muted focus:outline-none"
          />
        </div>
        <div className="max-h-[300px] overflow-y-auto py-1">
          {filtered.map((cmd, i) => (
            <button
              key={cmd.label}
              onClick={() => handleSelect(cmd)}
              className={`w-full text-left px-4 py-2.5 flex items-center gap-3 transition-colors ${
                i === selectedIndex ? "bg-cc-accent/10" : "hover:bg-cc-card-hover"
              }`}
            >
              <span className={`text-[10px] font-medium uppercase w-14 shrink-0 ${CATEGORY_COLORS[cmd.category]}`}>
                {CATEGORY_LABELS[cmd.category]}
              </span>
              <div className="flex-1 min-w-0">
                <div className="text-[13px] text-cc-text font-medium">{cmd.label}</div>
                <div className="text-[11px] text-cc-text-muted truncate">{cmd.description}</div>
              </div>
            </button>
          ))}
          {filtered.length === 0 && (
            <div className="px-4 py-6 text-center text-[12px] text-cc-text-muted">
              {b ? "No matching commands" : "배럭을 먼저 선택하세요"}
            </div>
          )}
        </div>
        <div className="px-4 py-2 border-t border-cc-border text-[10px] text-cc-text-muted flex gap-3">
          <span>↑↓ Navigate</span>
          <span>↵ Select</span>
          <span>esc Close</span>
        </div>
      </div>
    </div>
  );
}
