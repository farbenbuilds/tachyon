import { spawn } from "node:child_process";
import { once } from "node:events";
import { access, readFile, writeFile } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const benchesDir = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(benchesDir, "..");
const host = "127.0.0.1";
const duration = Number(process.env.BENCH_DURATION ?? 5);
const startDelayMs = Number(process.env.BENCH_START_DELAY_MS ?? 1000);
const loadTest =
  process.env.TACHYON_LOAD_TEST ?? path.join(rootDir, "zig-out/bin/tachyon-load-test");

const cases = [
  { connections: 100, payloadBytes: 20 },
  { connections: 10, payloadBytes: 1024 },
  { connections: 10, payloadBytes: 16 * 1024 },
  { connections: 200, payloadBytes: 16 * 1024 },
  { connections: 500, payloadBytes: 16 * 1024 },
];

const targets = [
  {
    name: "tachyon",
    command: path.resolve(
      rootDir,
      process.env.TACHYON_ECHO_SERVER ?? "zig-out/bin/tachyon-echo-server",
    ),
    args: [],
    port: 8080,
    env: { PORT: "8080" },
  },
  {
    name: "uWebSockets",
    command: path.resolve(
      rootDir,
      process.env.UWEBSOCKETS_SERVER ?? "benches/.servers/uWebSockets/EchoServer",
    ),
    args: [],
    port: 9001,
  },
  {
    name: "fastwebsockets",
    command: path.resolve(
      rootDir,
      process.env.FASTWEBSOCKETS_SERVER ?? "benches/.servers/fastwebsockets/echo_server",
    ),
    args: [],
    port: 8080,
  },
  {
    name: "tokio-tungstenite",
    command: path.resolve(
      rootDir,
      process.env.TOKIO_TUNGSTENITE_SERVER ??
        "benches/.servers/tokio-tungstenite/echo-server",
    ),
    args: [`${host}:8080`],
    port: 8080,
  },
  {
    name: "rust-websocket",
    command: path.resolve(
      rootDir,
      process.env.RUST_WEBSOCKET_SERVER ??
        "benches/.servers/rust-websocket/async-autobahn-server",
    ),
    args: [],
    port: 9002,
    // The old rust-websocket server can wedge on a bare TCP readiness probe;
    // wait for its startup delay instead and let the load test connect.
    probePort: false,
  },
];

let activeServer = null;
let shuttingDown = false;

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function fileExists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function waitForPort(port, child, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(
        `server exited before listening (${child.exitCode ?? child.signalCode})`,
      );
    }
    try {
      await new Promise((resolve, reject) => {
        const socket = net.connect({ host, port });
        socket.once("connect", () => {
          socket.destroy();
          resolve();
        });
        socket.once("error", (err) => {
          socket.destroy();
          reject(err);
        });
      });
      return;
    } catch {
      await delay(100);
    }
  }
  throw new Error(`timed out waiting for ${host}:${port}`);
}

function spawnServer(target) {
  const child = spawn(target.command, target.args, {
    cwd: rootDir,
    env: target.env ? { ...process.env, ...target.env } : process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", () => {});
  child.stderr.on("data", () => {});
  child.on("error", () => {});
  return child;
}

async function stopServer(child) {
  if (child === undefined || child.exitCode !== null || child.signalCode !== null) {
    return;
  }

  child.kill("SIGTERM");
  await Promise.race([once(child, "exit").catch(() => {}), delay(2_000)]);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
    await Promise.race([once(child, "exit").catch(() => {}), delay(1_000)]);
  }
}

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  const server = activeServer;
  activeServer = null;
  if (server) {
    await stopServer(server);
  }
  process.exit(signal === "SIGINT" ? 130 : 143);
}

process.once("SIGINT", () => {
  void shutdown("SIGINT");
});
process.once("SIGTERM", () => {
  void shutdown("SIGTERM");
});

async function runLoadTest(connections, payloadBytes, port) {
  const args = [
    host,
    String(port),
    String(connections),
    String(duration),
    String(payloadBytes),
  ];
  const child = spawn(loadTest, args, {
    cwd: rootDir,
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  const timer = setTimeout(
    () => child.kill("SIGKILL"),
    Math.max(30_000, duration * 10_000),
  );
  const exitCode = await new Promise((resolve) => {
    child.once("close", resolve);
    child.once("error", () => resolve(-1));
  });
  clearTimeout(timer);

  if (exitCode !== 0) {
    throw new Error(
      `load test exited ${exitCode}${stderr.trim() ? `: ${stderr.trim()}` : ""}`,
    );
  }

  const output = `${stdout}\n${stderr}`;
  const samples = [];
  for (const line of output.split(/\r?\n/)) {
    const match = /^Msg\/sec\s+([0-9]+(?:\.[0-9]+)?)$/.exec(line.trim());
    if (match) samples.push(Number(match[1]));
  }
  if (samples.length === 0) {
    throw new Error("load test produced no Msg/sec samples");
  }

  const final = /^Final Msg\/sec [0-9]+ \(total [0-9]+, errors ([0-9]+)\)$/m.exec(
    output,
  );
  if (final && Number(final[1]) > 0) {
    throw new Error(`load test reported ${final[1]} connection errors`);
  }

  const average =
    samples.reduce((sum, sample) => sum + sample, 0) / samples.length;
  return { average, samples };
}


function chartFileName(testCase) {
  return `${testCase.connections}-${testCase.payloadBytes}-chart.svg`;
}

function escapeXml(value) {
  return String(value).replace(/[&<>"']/g, (char) => {
    switch (char) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      default:
        return "&apos;";
    }
  });
}

function formatCount(value) {
  return Math.round(value)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function renderChart(testCase, rows) {
  const width = 960;
  const left = 260;
  const right = 120;
  const top = 96;
  const rowHeight = 52;
  const barHeight = 32;
  const height = Math.max(260, top + rows.length * rowHeight + 48);
  const plotWidth = width - left - right;
  const maxValue = Math.max(1, ...rows.map((row) => row.avg_msg_per_sec));
  const title = `Connections: ${testCase.connections}, Payload: ${testCase.payloadBytes} bytes`;
  const palette = ["#4e79a7", "#f28e2b", "#59a14f", "#e15759", "#b07aa1"];
  const parts = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="chart-title">`,
    `  <title id="chart-title">${escapeXml(title)}</title>`,
    '  <rect width="100%" height="100%" fill="#ffffff"/>',
    `  <text x="24" y="38" font-family="sans-serif" font-size="20" font-weight="bold" fill="#222">${escapeXml(title)}</text>`,
    `  <text x="24" y="62" font-family="sans-serif" font-size="13" fill="#666">Average Msg/sec, sorted by target</text>`,
    `  <line x1="${left}" y1="78" x2="${width - 24}" y2="78" stroke="#dddddd"/>`,
  ];

  if (rows.length === 0) {
    parts.push(
      '  <text x="24" y="120" font-family="sans-serif" font-size="14" fill="#666">No successful target results</text>',
    );
  } else {
    rows.forEach((row, index) => {
      const y = top + index * rowHeight;
      const barWidth = plotWidth * (row.avg_msg_per_sec / maxValue);
      const color = palette[index % palette.length];
      parts.push(
        `  <text x="24" y="${y + 21}" font-family="sans-serif" font-size="14" fill="#222">${escapeXml(row.target)}</text>`,
        `  <rect x="${left}" y="${y}" width="${barWidth.toFixed(1)}" height="${barHeight}" fill="${color}" rx="3"/>`,
        `  <text x="${width - 24}" y="${y + 21}" text-anchor="end" font-family="sans-serif" font-size="13" fill="#222">${formatCount(row.avg_msg_per_sec)}</text>`,
      );
    });
  }

  parts.push("</svg>");
  return `${parts.join("\n")}\n`;
}

async function main() {
  if (!(await fileExists(loadTest))) {
    throw new Error(
      `missing ${loadTest}; run: zig build examples benches -Doptimize=ReleaseFast`,
    );
  }

  const available = [];
  const missing = [];
  for (const target of targets) {
    let reason = null;
    if (!(await fileExists(target.command))) {
      reason = `missing ${target.command}`;
    }
    if (reason !== null) {
      missing.push({ name: target.name, reason });
      console.log(`skip ${target.name}: ${reason}`);
    } else {
      available.push(target);
    }
  }

  const results = [];
  const errors = [];

  for (const testCase of cases) {
    for (const target of available) {
      let server;
      try {
        console.log(
          `run ${target.name}: ${testCase.connections} connections, ${testCase.payloadBytes} bytes`,
        );
        server = spawnServer(target);
        activeServer = server;
        if (target.probePort !== false) {
          await waitForPort(target.port, server);
        }
        await delay(startDelayMs);
        const result = await runLoadTest(
          testCase.connections,
          testCase.payloadBytes,
          target.port,
        );
        results.push({
          target: target.name,
          connections: testCase.connections,
          payload_bytes: testCase.payloadBytes,
          avg_msg_per_sec: Math.round(result.average),
          samples: result.samples,
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        errors.push({
          target: target.name,
          connections: testCase.connections,
          payload_bytes: testCase.payloadBytes,
          error: message,
        });
        console.error(`fail ${target.name}: ${message}`);
      } finally {
        await stopServer(server);
        if (activeServer === server) activeServer = null;
      }
    }
  }

  const generatedAt = new Date().toISOString();
  const markdown = [
    `Generated: ${generatedAt}`,
    `Duration: ${duration}s per case`,
    "",
    "| Target | Connections | Payload | Avg Msg/sec |",
    "| --- | ---: | ---: | ---: |",
    ...results.map(
      (result) =>
        `| ${result.target} | ${result.connections} | ${result.payload_bytes} B | ${result.avg_msg_per_sec} |`,
    ),
  ];

  for (const testCase of cases) {
    const rows = results
      .filter(
        (result) =>
          result.connections === testCase.connections &&
          result.payload_bytes === testCase.payloadBytes,
      )
      .sort((left, right) => right.avg_msg_per_sec - left.avg_msg_per_sec);
    await writeFile(
      path.join(benchesDir, chartFileName(testCase)),
      renderChart(testCase, rows),
    );
  }

  if (missing.length > 0) {
    markdown.push("", "Skipped targets:", "");
    for (const item of missing) {
      markdown.push(`- ${item.name}: ${item.reason}`);
    }
  }
  if (errors.length > 0) {
    markdown.push("", "Errors:", "");
    for (const item of errors) {
      markdown.push(
        `- ${item.target} (${item.connections} connections, ${item.payload_bytes} B): ${item.error}`,
      );
    }
  }

  markdown.push("", "### Charts", "");
  for (const testCase of cases) {
    markdown.push(
      `![Connections: ${testCase.connections}, Payload: ${testCase.payloadBytes} bytes](${chartFileName(testCase)})`,
      "",
    );
  }

  const readmePath = path.join(benchesDir, "README.md");
  const readme = await readFile(readmePath, "utf8");
  const startMarker = "<!-- bench-results:start -->";
  const endMarker = "<!-- bench-results:end -->";
  const start = readme.indexOf(startMarker);
  const end = readme.indexOf(endMarker);
  if (start < 0 || end < 0 || end < start) {
    throw new Error(
      `missing ${startMarker} or ${endMarker} in ${readmePath}`,
    );
  }

  const block = `\n${markdown.join("\n").trimEnd()}\n`;
  const updated =
    readme.slice(0, start + startMarker.length) +
    block +
    readme.slice(end);
  await writeFile(readmePath, updated);

  console.log(markdown.join("\n"));

  if (results.length === 0) {
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exitCode = 1;
});
