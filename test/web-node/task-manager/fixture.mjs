// A `system.top` / `system.memory` reply shaped like `cmux top --json --all
// --processes`: two windows, a hidden one, terminal and browser surfaces,
// a status tag, an agent with helpers and a `sleep 1000`.
export const IDS = Object.freeze({
  win1: "A0000000-0000-4000-8000-000000000001",
  win2: "A0000000-0000-4000-8000-000000000002",
  wsApi: "B0000000-0000-4000-8000-000000000001",
  wsWeb: "B0000000-0000-4000-8000-000000000002",
  wsIdle: "B0000000-0000-4000-8000-000000000003",
  pane1: "C0000000-0000-4000-8000-000000000001",
  pane2: "C0000000-0000-4000-8000-000000000002",
  surfTerm: "D0000000-0000-4000-8000-000000000001",
  surfBrowser: "D0000000-0000-4000-8000-000000000002",
  surfSleep: "D0000000-0000-4000-8000-000000000003",
});

const MB = 1024 * 1024;

export function topReply() {
  return {
    windows: [
      {
        id: IDS.win1,
        ref: "window:1",
        key: true,
        cpu_percent: 130.5,
        memory_bytes: 900 * MB,
        process_count: 6,
        workspaces: [
          {
            id: IDS.wsApi,
            ref: "workspace:1",
            title: "api <server>",
            selected: true,
            cpu_percent: 120.5,
            memory_bytes: 700 * MB,
            process_count: 5,
            tags: [
              {
                key: "build",
                value: "watch",
                pid: 501,
                pid_only: false,
                cpu_percent: 0.5,
                memory_bytes: 20 * MB,
                process_count: 1,
                processes: [{ pid: 501, name: "watcher.exe", cpu_percent: 0.5, memory_bytes: 20 * MB }],
              },
            ],
            panes: [
              {
                id: IDS.pane1,
                ref: "pane:1",
                focused: true,
                cpu_percent: 120,
                memory_bytes: 680 * MB,
                process_count: 4,
                surfaces: [
                  {
                    id: IDS.surfTerm,
                    ref: "surface:1",
                    type: "terminal",
                    title: "pwsh",
                    selected: true,
                    tty: "conpty-1",
                    cpu_percent: 120,
                    memory_bytes: 680 * MB,
                    process_count: 4,
                    processes: [
                      {
                        pid: 100,
                        name: "pwsh.exe",
                        cpu_percent: 0.2,
                        memory_bytes: 80 * MB,
                        children: [
                          {
                            pid: 200,
                            name: "claude.exe",
                            cpu_percent: 99.8,
                            memory_bytes: 400 * MB,
                            children: [
                              { pid: 300, name: "node.exe", cpu_percent: 15, memory_bytes: 150 * MB },
                              { pid: 301, name: "rg.exe", cpu_percent: 5, memory_bytes: 50 * MB },
                            ],
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
          {
            id: IDS.wsWeb,
            ref: "workspace:2",
            title: "docs",
            pinned: true,
            cpu_percent: 10,
            memory_bytes: 200 * MB,
            process_count: 1,
            panes: [
              {
                id: IDS.pane2,
                ref: "pane:2",
                cpu_percent: 10,
                memory_bytes: 200 * MB,
                process_count: 1,
                surfaces: [
                  {
                    id: IDS.surfBrowser,
                    ref: "surface:2",
                    type: "browser",
                    title: "Docs",
                    cpu_percent: 10,
                    memory_bytes: 200 * MB,
                    process_count: 1,
                    webviews: [
                      {
                        pid: 900,
                        title: "docs.example",
                        cpu_percent: 10,
                        memory_bytes: 200 * MB,
                        process_count: 1,
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        id: IDS.win2,
        ref: "window:2",
        hidden: true,
        cpu_percent: 0,
        memory_bytes: 5 * MB,
        process_count: 1,
        workspaces: [
          {
            id: IDS.wsIdle,
            ref: "workspace:3",
            title: "idle",
            panes: [
              {
                ref: "pane:3",
                surfaces: [
                  {
                    id: IDS.surfSleep,
                    ref: "surface:3",
                    type: "terminal",
                    title: "sleep",
                    processes: [{ pid: 4242, name: "sleep", cpu_percent: 0, memory_bytes: 5 * MB }],
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
    totals: { cpu_percent: 130.5, memory_bytes: 905 * MB, process_count: 7 },
  };
}

export function memoryReply() {
  return {
    app: { memory_bytes: 250 * MB },
    child: { memory_bytes: 705 * MB, process_count: 7 },
    groups: [
      { command: "claude", memory_bytes: 400 * MB, process_count: 1, workspaces: ["api <server>"] },
      { command: "node", memory_bytes: 150 * MB, process_count: 1, workspaces: [{ title: "api <server>" }] },
      { command: "sleep", memory_bytes: 5 * MB, process_count: 1, workspaces: ["idle"] },
    ],
  };
}

export { MB };
